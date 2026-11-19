import AppKit

/// Settings for subtitles on the Touch Bar.
public enum SubtitleSettings {
	private static let d = UserDefaults.standard
	public static let didChange = Notification.Name("pockai.subtitles.settingsChanged")
	private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

	/// Subtitles shown (long-press the widget to hide / show).
	public static var visible: Bool {
		get { d.object(forKey: "pockai.subs.visible") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.subs.visible"); changed() }
	}
	public static var width: CGFloat {
		get { CGFloat(d.object(forKey: "pockai.subs.width") as? Double ?? 360) }
		set { d.set(Double(newValue), forKey: "pockai.subs.width"); changed() }
	}
	/// Collapse the widget when there is nothing to show.
	public static var hideWhenEmpty: Bool {
		get { d.object(forKey: "pockai.subs.hideEmpty") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.subs.hideEmpty"); changed() }
	}
	/// Browser extension bridge (Netflix, YouTube, Prime Video, Disney+, …).
	public static var browserBridge: Bool {
		get { d.object(forKey: "pockai.subs.bridge") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.subs.bridge"); changed() }
	}
	/// .srt / .vtt next to the video in local players (IINA, VLC, QuickTime, …).
	public static var localFiles: Bool {
		get { d.object(forKey: "pockai.subs.local") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.subs.local"); changed() }
	}
	/// Read subtitles from the screen with on-device text recognition (any app). Needs Screen Recording.
	public static var screenReader: Bool {
		get { d.object(forKey: "pockai.subs.ocr") as? Bool ?? false }
		set { d.set(newValue, forKey: "pockai.subs.ocr"); changed() }
	}
	/// No room in the Pock bar: show captions full-width automatically while they come in.
	public static var autoFullBar: Bool {
		get { d.object(forKey: "pockai.subs.autoFull") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.subs.autoFull"); changed() }
	}
	/// Seconds added to local subtitle timing (negative = earlier).
	public static var offset: Double {
		get { d.double(forKey: "pockai.subs.offset") }
		set { d.set(newValue, forKey: "pockai.subs.offset"); changed() }
	}
}

/// Collects subtitle text from every source and tells the widgets what to show.
public final class SubtitleCenter {

	public static let shared = SubtitleCenter()

	public enum Source: String { case browser = "Browser", file = "Subtitle file", screen = "Screen" }

	public private(set) var text = ""
	public private(set) var source: Source?
	/// e.g. "Netflix", "YouTube", or the subtitle file name.
	public private(set) var origin = ""
	private var lastUpdate = Date.distantPast

	private var listeners: [UUID: () -> Void] = [:]
	private var expiry: Timer?
	private var settingsObserver: NSObjectProtocol?

	private let server = SubtitleServer()
	private let files = LocalSubtitles()
	private let screen = ScreenSubtitleReader()

	private init() {}

	@discardableResult
	public func observe(_ handler: @escaping () -> Void) -> UUID {
		let id = UUID()
		listeners[id] = handler
		if listeners.count == 1 { startSources() }
		handler()
		return id
	}

	public func removeObserver(_ id: UUID?) {
		guard let id else { return }
		listeners[id] = nil
		if listeners.isEmpty { stopSources() }
	}

	private func notify() { listeners.values.forEach { $0() } }

	// MARK: Sources

	private func startSources() {
		applySettings()
		settingsObserver = NotificationCenter.default.addObserver(forName: SubtitleSettings.didChange, object: nil, queue: .main) { [weak self] _ in
			self?.applySettings()
		}
	}

	private func stopSources() {
		if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
		settingsObserver = nil
		server.stop()
		files.stop()
		screen.stop()
	}

	private func applySettings() {
		let sink: (String, Source, String) -> Void = { [weak self] text, source, origin in
			self?.receive(text, from: source, origin: origin)
		}
		if SubtitleSettings.browserBridge { server.start(sink) } else { server.stop() }
		if SubtitleSettings.localFiles { files.start(sink) } else { files.stop() }
		if SubtitleSettings.screenReader { screen.start(sink) } else { screen.stop() }
	}

	/// Load a subtitle file by hand (menu: "Load Subtitle File…"); it follows the now-playing position.
	public func loadFile(_ url: URL) {
		files.load(url)
		if listeners.isEmpty { files.start { [weak self] t, s, o in self?.receive(t, from: s, origin: o) } }
	}

	public var loadedFileName: String? { files.loadedName }

	// MARK: Data

	private func receive(_ raw: String, from source: Source, origin: String) {
		// Newer sources win: a browser caption overrides a stale file line, etc.
		let cleaned = Self.clean(raw)
		if cleaned.isEmpty {
			// Only the source that set the text may clear it.
			guard self.source == source || self.source == nil else { return }
		}
		lastUpdate = Date()
		guard cleaned != text || self.source != source else { return }
		text = cleaned
		self.source = cleaned.isEmpty ? nil : source
		self.origin = origin
		scheduleExpiry()
		notify()
	}

	/// Captions left on screen with no update for a long while are cleared (tab closed, extension paused…).
	private func scheduleExpiry() {
		expiry?.invalidate()
		guard !text.isEmpty else { return }
		expiry = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
			guard let self, Date().timeIntervalSince(self.lastUpdate) >= 11.5 else { return }
			self.text = ""
			self.source = nil
			self.notify()
		}
	}

	/// Strip HTML/ASS tags and speaker dashes clutter; join lines.
	static func clean(_ s: String) -> String {
		var t = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
		t = t.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
		t = t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
		let lines = t.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }
		return lines.joined(separator: "\n")
	}
}
