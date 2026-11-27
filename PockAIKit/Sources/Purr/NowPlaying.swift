import AppKit
import QuartzCore
import CoreText
import CoreImage
import CoreAudio
import Accelerate
import NaturalLanguage
import SwiftUI
import Translation
import IOKit.ps
import IOKit.pwr_mgt
import CoreGraphics

// MARK: - Model

public struct NowPlaying {
    public var playing = false
    public var app: String?
    public var title = "", artist = "", album = ""
    public var duration = 0.0, elapsed = 0.0, rate = 0.0
    public var ts: Double?
    public var artKey: String?
    public var received = Date()

    public var hasContent: Bool { !title.isEmpty }
    public var trackKey: String { "\(app ?? "")|\(title)|\(artist)" }
    /// Playback position right now, extrapolated from the last report.
    public var current: Double {
        guard playing, rate > 0 else { return elapsed }
        let base = ts.map { Date(timeIntervalSince1970: $0) } ?? received
        let t = elapsed + Date().timeIntervalSince(base) * rate
        return duration > 0 ? min(t, duration) : t
    }

    public init() {}
    init(_ d: [String: Any]) {
        playing = d["playing"] as? Bool ?? false
        app = d["app"] as? String
        title = d["title"] as? String ?? ""
        artist = d["artist"] as? String ?? ""
        album = d["album"] as? String ?? ""
        duration = (d["duration"] as? NSNumber)?.doubleValue ?? 0
        elapsed = (d["elapsed"] as? NSNumber)?.doubleValue ?? 0
        rate = (d["rate"] as? NSNumber)?.doubleValue ?? 0
        ts = (d["ts"] as? NSNumber)?.doubleValue
        artKey = d["artKey"] as? String
    }
}

// MARK: - Now-playing helper process

final class Helper {
    var onUpdate: (([String: Any]) -> Void)?
    private var proc: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopping = false
    private var failures = 0
    private var lastStart = Date.distantPast

    private static var resourcePath: String? { Bundle(for: Helper.self).resourcePath }

    func start() {
        stopping = false
        guard proc == nil, let res = Self.resourcePath,
              FileManager.default.fileExists(atPath: res + "/np.pl"),
              FileManager.default.fileExists(atPath: res + "/libnowplaying.dylib") else {
            NSLog("[TouchPlay][NowPlaying] helper resources missing")
            return
        }
        lastStart = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res + "/np.pl", res + "/libnowplaying.dylib"]
        let pipe = Pipe()
        let inPipe = Pipe()
        p.standardOutput = pipe
        p.standardInput = inPipe
        p.standardError = FileHandle.nullDevice
        input = inPipe.fileHandleForWriting
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.proc = nil
                self.input = nil
                self.buffer.removeAll()
                guard !self.stopping else { return }
                // Crashed or killed: restart, backing off if it keeps dying right away.
                self.failures = Date().timeIntervalSince(self.lastStart) < 5 ? self.failures + 1 : 0
                let delay = min(60, pow(2, Double(self.failures)))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.stopping else { return }
                    self.start()
                }
            }
        }
        do { try p.run(); proc = p } catch { NSLog("[TouchPlay][NowPlaying] helper failed: \(error)") }
    }

    func stop() {
        stopping = true
        proc?.terminate()
        proc = nil
        input = nil
    }

    func send(_ line: String) {
        guard let input else { return }
        // Writing to a closed pipe raises; the helper may have just exited.
        do { try input.write(contentsOf: Data((line + "\n").utf8)) } catch { }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        // Never let a malformed stream grow without bound.
        if buffer.count > 8_000_000 { buffer.removeAll(); return }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { onUpdate?(obj) }
        }
    }
}
