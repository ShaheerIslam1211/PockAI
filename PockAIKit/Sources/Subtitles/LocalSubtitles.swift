import AppKit
import ApplicationServices

/// A parsed .srt / .vtt subtitle track.
struct SubtitleTrack {
	struct Cue { let start: Double; let end: Double; let text: String }
	let cues: [Cue]

	func text(at t: Double) -> String {
		// Binary search for the last cue starting before t.
		var lo = 0, hi = cues.count - 1, found = -1
		while lo <= hi {
			let mid = (lo + hi) / 2
			if cues[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
		}
		guard found >= 0 else { return "" }
		// Overlapping cues: show every cue covering t.
		var lines: [String] = []
		var i = found
		while i >= 0 && i >= found - 3 {
			if cues[i].start <= t && t < cues[i].end { lines.insert(cues[i].text, at: 0) }
			i -= 1
		}
		return lines.joined(separator: "\n")
	}

	static func load(_ url: URL) -> SubtitleTrack? {
		guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
		let text = String(data: data, encoding: .utf8)
			?? String(data: data, encoding: .utf16)
			?? String(data: data, encoding: .windowsCP1252)
			?? String(data: data, encoding: .isoLatin1) ?? ""
		let track = parse(text)
		return track.cues.isEmpty ? nil : track
	}

	/// Handles SRT and WebVTT ("00:01:02,345 --> 00:01:04,000" or "01:02.345 --> 01:04.000").
	static func parse(_ text: String) -> SubtitleTrack {
		let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		var cues: [Cue] = []
		for block in normalized.components(separatedBy: "\n\n") {
			let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
			let parts = lines[timingIndex].components(separatedBy: "-->")
			guard parts.count == 2,
				  let start = time(parts[0]),
				  let end = time(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else { continue }
			let body = lines[(timingIndex + 1)...].joined(separator: "\n")
			guard !body.isEmpty else { continue }
			cues.append(Cue(start: start, end: max(end, start + 0.3), text: SubtitleCenter.clean(body)))
		}
		return SubtitleTrack(cues: cues.sorted { $0.start < $1.start })
	}

	static func time(_ raw: String) -> Double? {
		let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
		let comps = s.split(separator: ":").map(String.init)
		guard !comps.isEmpty, comps.count <= 3 else { return nil }
		var total = 0.0
		for c in comps {
			guard let v = Double(c) else { return nil }
			total = total * 60 + v
		}
		return total
	}
}

/// Subtitles for local videos: finds the .srt/.vtt next to the movie that's open in the player
/// (IINA, VLC, QuickTime, Infuse, Movist…) and follows the now-playing position.
final class LocalSubtitles {

	private var sink: ((String, SubtitleCenter.Source, String) -> Void)?
	private var npToken: UUID?
	private var timer: Timer?
	private var track: SubtitleTrack?
	private var trackFor = ""
	private(set) var loadedName: String?
	private var manual = false
	private var lastText = ""
	private var state = NowPlaying()

	static let videoPlayers: Set<String> = [
		"com.colliderli.iina", "org.videolan.vlc", "com.apple.QuickTimePlayerX", "com.firecore.infuse",
		"com.movist.MovistPro", "io.mpv", "com.apple.TV", "net.elmedia.elmedia", "com.apple.Safari"
	]

	func start(_ sink: @escaping (String, SubtitleCenter.Source, String) -> Void) {
		self.sink = sink
		guard npToken == nil else { return }
		npToken = NowPlayingCenter.shared.subscribe { [weak self] s, _ in self?.receive(s) }
	}

	func stop() {
		NowPlayingCenter.shared.unsubscribe(npToken)
		npToken = nil
		timer?.invalidate(); timer = nil
	}

	func load(_ url: URL) {
		guard let t = SubtitleTrack.load(url) else { return }
		track = t
		manual = true
		loadedName = url.lastPathComponent
		trackFor = NowPlayingCenter.shared.state.trackKey
		restartTimer()
	}

	private func receive(_ s: NowPlaying) {
		state = s
		if s.trackKey != trackFor {
			trackFor = s.trackKey
			if !manual { track = nil; loadedName = nil }
			manual = false
			if s.hasContent { findTrack(for: s) }
			emit("")
		}
		restartTimer()
	}

	private func restartTimer() {
		timer?.invalidate(); timer = nil
		guard track != nil, state.playing else { return }
		let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
		t.tolerance = 0.05
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	private func tick() {
		guard let track else { return }
		emit(track.text(at: state.current + SubtitleSettings.offset))
	}

	private func emit(_ text: String) {
		guard text != lastText else { return }
		lastText = text
		sink?(text, .file, loadedName ?? "Subtitles")
	}

	// MARK: Finding the subtitle file

	private func findTrack(for s: NowPlaying) {
		guard let app = s.app else { return }
		let candidates = documentURLs(of: app)
		DispatchQueue.global(qos: .utility).async { [weak self] in
			for video in candidates {
				if let url = Self.sidecar(for: video), let t = SubtitleTrack.load(url) {
					DispatchQueue.main.async {
						guard let self, self.trackFor == s.trackKey else { return }
						self.track = t
						self.loadedName = url.lastPathComponent
						self.restartTimer()
					}
					return
				}
			}
		}
	}

	/// Files open in the player's windows (Accessibility `AXDocument`).
	private func documentURLs(of bundleID: String) -> [URL] {
		guard AXIsProcessTrusted(),
			  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
		let element = AXUIElementCreateApplication(app.processIdentifier)
		var windows: CFTypeRef?
		guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
			  let list = windows as? [AXUIElement] else { return [] }
		var urls: [URL] = []
		for window in list.prefix(6) {
			var doc: CFTypeRef?
			if AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &doc) == .success,
			   let string = doc as? String, let url = URL(string: string), url.isFileURL {
				urls.append(url)
			}
		}
		return urls
	}

	/// movie.mkv → movie.srt, movie.en.srt, movie.vtt, or a lone .srt in the same folder.
	static func sidecar(for video: URL) -> URL? {
		let folder = video.deletingLastPathComponent()
		let base = video.deletingPathExtension().lastPathComponent.lowercased()
		guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
		let subs = items.filter { ["srt", "vtt"].contains($0.pathExtension.lowercased()) }
		if let exact = subs.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == base }) { return exact }
		let preferred = ["en", "eng", "english"]
		if let lang = subs.first(where: {
			let name = $0.deletingPathExtension().lastPathComponent.lowercased()
			return name.hasPrefix(base) && preferred.contains(where: { name.hasSuffix("." + $0) })
		}) { return lang }
		if let prefixed = subs.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(base) }) { return prefixed }
		return subs.count == 1 ? subs[0] : nil
	}
}
