import AppKit

/// One shared now-playing source for every widget (Now Playing, Lyrics, Purr player, Subtitles).
///
/// Since macOS 15.4 only Apple-signed processes may read MediaRemote, so the work is done by
/// `/usr/bin/perl` hosting `libnowplaying.dylib` (from Purrbar). Only one helper process runs,
/// started when the first widget subscribes and stopped when the last one leaves.
public final class NowPlayingCenter {

	public static let shared = NowPlayingCenter()

	/// Latest state.
	public private(set) var state = NowPlaying()
	/// Latest artwork (decoded once, shared).
	public private(set) var artwork: NSImage?
	public private(set) var artworkKey: String?

	public typealias Handler = (_ state: NowPlaying, _ artworkChanged: Bool) -> Void

	private var subscribers: [UUID: Handler] = [:]
	private let helper = Helper()
	private var running = false

	private init() {
		helper.onUpdate = { [weak self] dict in self?.receive(dict) }
	}

	/// Subscribe to updates. Keep the token; pass it to `unsubscribe` (e.g. in `deinit`).
	@discardableResult
	public func subscribe(_ handler: @escaping Handler) -> UUID {
		let token = UUID()
		subscribers[token] = handler
		if !running {
			running = true
			helper.start()
		}
		// Give the newcomer the current state right away.
		let current = state
		DispatchQueue.main.async { handler(current, true) }
		return token
	}

	public func unsubscribe(_ token: UUID?) {
		guard let token else { return }
		subscribers[token] = nil
		if subscribers.isEmpty && running {
			running = false
			helper.stop()
		}
	}

	// MARK: Commands

	public enum Command: Int32 { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

	public func send(_ command: Command) {
		helper.send("cmd \(command.rawValue)")
		if command == .toggle {
			state.playing.toggle()
			broadcast(artworkChanged: false)
		}
	}

	public func seek(to seconds: Double) {
		helper.send("seek \(seconds)")
	}

	/// Raw line passthrough (used by the Purr player, which speaks the helper protocol directly).
	func sendRaw(_ line: String) { helper.send(line) }

	// MARK: Data

	private func receive(_ d: [String: Any]) {
		var np = NowPlaying(d)
		np.received = Date()
		var artChanged = false
		if let b64 = d["art"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
			artwork = img
			artworkKey = np.artKey
			artChanged = true
		} else if np.artKey != artworkKey {
			artwork = nil
			artworkKey = np.artKey
			artChanged = true
		}
		state = np
		broadcast(artworkChanged: artChanged)
	}

	private func broadcast(artworkChanged: Bool) {
		let s = state
		for handler in subscribers.values { handler(s, artworkChanged) }
	}

	// MARK: Helpers shared by widgets

	/// YouTube-style titles carry "(Official Video)", "| Channel" and similar noise.
	public static func cleanTitle(_ t: String) -> String {
		var s = t
		if let bar = s.range(of: " | ") { s = String(s[..<bar.lowerBound]) }
		s = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|remaster)[^\)\]]*[\)\]]"#,
								   with: "", options: [.regularExpression, .caseInsensitive])
		s = s.replacingOccurrences(of: #"\.(wav|mp3|m4a|flac|aac|ogg|opus)$"#, with: "", options: [.regularExpression, .caseInsensitive])
		s = s.trimmingCharacters(in: .whitespaces)
		return s.isEmpty ? t : s
	}

	public static func appName(_ id: String?) -> String? {
		guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
		return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
	}

	public static func appIcon(_ id: String?) -> NSImage? {
		guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
		return NSWorkspace.shared.icon(forFile: url.path)
	}
}
