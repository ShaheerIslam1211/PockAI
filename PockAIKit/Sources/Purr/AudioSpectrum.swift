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

// MARK: - Live spectrum of whatever the Mac is playing (Core Audio process tap, macOS 14.2+)

// Runs only while the music-break bars are on screen. Needs "System Audio Recording" permission;
// without it the tap delivers silence and the bars fall back to their canned animation.
final class AudioSpectrum {
    static let bands = 18
    var onBands: (([Float]) -> Void)?
    private(set) var running = false
    private(set) var gotSignal = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "local.touchbarplayer.spectrum")

    private let n = 2048
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringPos = 0
    private var sampleRate = 48000.0
    private var smoothed = [Float](repeating: 0, count: AudioSpectrum.bands)
    private var ceilingDb: Float = -30
    private var lastEmit = 0.0
    var fps = 24.0            // battery saver drops this to 12

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: n)
    }

    deinit {
        stop()
        vDSP_destroy_fftsetup(setup)
    }

    func start() -> Bool {
        guard !running else { return true }
        // The system-audio tap exists from macOS 14.2; older systems get the animated (fake) equaliser.
        guard #available(macOS 14.2, *) else { return false }
        gotSignal = false
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return false }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        guard let outputUID = Self.defaultOutputUID() else { stop(); return false }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TouchBarPlayer Spectrum",
            kAudioAggregateDeviceUIDKey: "local.touchbarplayer.spectrum." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg) == noErr else { stop(); return false }
        aggregateID = agg

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else { stop(); return false }
        procID = proc
        guard AudioDeviceStart(agg, proc) == noErr else { stop(); return false }
        running = true
        return true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        running = false
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let u = uid else { return nil }
        return u.takeRetainedValue() as String
    }

    // Audio thread: mix to mono into a ring buffer, and ~30 times a second turn the latest 2048 samples into 18 bands.
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = abl.first, first.mData != nil else { return }
        let interleaved = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * interleaved)
        let buffers = abl.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
        let scale = 1 / Float(interleaved * buffers.count)
        for f in 0..<frames {
            var v: Float = 0
            for p in buffers { for c in 0..<interleaved { v += p[f * interleaved + c] } }
            v *= scale
            if !gotSignal && abs(v) > 1e-4 { gotSignal = true }
            ring[ringPos] = v
            ringPos = (ringPos + 1) & (n - 1)
        }
        let now = CACurrentMediaTime()
        guard now - lastEmit >= 1.0 / fps else { return }
        lastEmit = now
        let out = analyse()
        DispatchQueue.main.async { [weak self] in self?.onBands?(out) }
    }

    private func analyse() -> [Float] {
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n { frame[i] = ring[(ringPos + i) & (n - 1)] * window[i] }
        var re = [Float](repeating: 0, count: n / 2)
        var im = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                power.withUnsafeMutableBufferPointer { pp in
                    vDSP_zvmags(&split, 1, pp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }
        // Log-spaced bands 50 Hz – 14 kHz, tilted up a little so treble isn't always flat.
        let binHz = sampleRate / Double(n)
        let lo = 70.0, hi = 14000.0
        var db = [Float](repeating: -120, count: Self.bands)
        for k in 0..<Self.bands {
            let f0 = lo * pow(hi / lo, Double(k) / Double(Self.bands))
            let f1 = lo * pow(hi / lo, Double(k + 1) / Double(Self.bands))
            let b0 = max(1, Int(f0 / binHz)), b1 = min(n / 2 - 1, max(b0 + 1, Int(f1 / binHz)))
            var sum: Float = 0
            for b in b0..<b1 { sum += power[b] }
            db[k] = 10 * log10(sum / Float(b1 - b0) + 1e-12) + Float(k) * 1.2
        }
        // Auto-gain: follow the loudest band, fall back slowly, show the top 30 dB below it.
        let loudest = db.max() ?? -120
        ceilingDb = max(loudest, ceilingDb - 0.4)
        for k in 0..<Self.bands {
            // Curve so peaks stand out and quieter bands sit low instead of everything hovering near the top.
            let v = pow(max(0, min(1, (db[k] - (ceilingDb - 30)) / 30)), 1.8)
            smoothed[k] = v > smoothed[k] ? smoothed[k] + (v - smoothed[k]) * 0.75 : smoothed[k] * 0.75 + v * 0.25
        }
        return smoothed
    }
}
