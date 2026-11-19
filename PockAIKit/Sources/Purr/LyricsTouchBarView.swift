import AppKit

/// Settings for the inline Lyrics widget.
public enum LyricsWidgetSettings {
	private static let d = UserDefaults.standard
	public static var width: CGFloat {
		get { CGFloat(d.object(forKey: "pockai.lyrics.width") as? Double ?? 280) }
		set { d.set(Double(newValue), forKey: "pockai.lyrics.width"); changed() }
	}
	public static var showArtwork: Bool {
		get { d.object(forKey: "pockai.lyrics.artwork") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.lyrics.artwork"); changed() }
	}
	public static var showNextLine: Bool {
		get { d.object(forKey: "pockai.lyrics.nextLine") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.lyrics.nextLine"); changed() }
	}
	public static var hideWhenIdle: Bool {
		get { d.object(forKey: "pockai.lyrics.hideIdle") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.lyrics.hideIdle"); changed() }
	}
	/// Lyrics on, or just the song title (long-press the widget to switch).
	public static var lyricsOn: Bool {
		get { d.object(forKey: "pockai.lyrics.on") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.lyrics.on"); changed() }
	}
	/// No room in the Pock bar for lyrics: open the full Purr player when a song starts.
	public static var fullPlayerWhenNoRoom: Bool {
		get { d.object(forKey: "pockai.lyrics.fullWhenNoRoom") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.lyrics.fullWhenNoRoom"); changed() }
	}
	public static let didChange = Notification.Name("pockai.lyrics.settingsChanged")
	private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }
}

/// Compact lyrics line for the Pock bar: artwork + karaoke-highlighted current line (+ next line).
/// Tap: open the full Purr player. Long press: hide / show lyrics. Swipe: next / previous track.
public final class LyricsTouchBarView: TouchView {

	private let artView = NSImageView()
	private let line = LineView(frame: .zero)
	private var npToken: UUID?
	private var lyricsToken: UUID?
	private var timer: Timer?
	private var state = NowPlaying()
	private var clock = 0.0
	private var clockKey = ""
	private var autoOpenedFor: String?
	private var compact = false

	public init() {
		super.init(width: LyricsWidgetSettings.width, collapsed: LyricsWidgetSettings.hideWhenIdle && NowPlayingCenter.shared.state.artist.isEmpty)
		layer?.cornerRadius = 6
		layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
		artView.imageScaling = .scaleProportionallyUpOrDown
		artView.wantsLayer = true
		artView.layer?.cornerRadius = 4
		artView.layer?.masksToBounds = true
		addSubview(artView)
		addSubview(line)
		onTap = {
			if LyricsStore.shared.status == .notFound { LyricsStore.shared.retry() }
			PurrPlayer.shared.show(lyrics: true)
		}
		onLongPress = { LyricsWidgetSettings.lyricsOn.toggle() }
		onSwipeLeft = { NowPlayingCenter.shared.send(.next) }
		onSwipeRight = { NowPlayingCenter.shared.send(.previous) }
		NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: LyricsWidgetSettings.didChange, object: nil)
		set(idle: "♪  Lyrics")
	}

	required init?(coder: NSCoder) { super.init(coder: coder) }

	deinit {
		NotificationCenter.default.removeObserver(self)
		stop()
	}

	// MARK: Lifecycle (called by the widget when it appears / disappears)

	public func start() {
		if npToken == nil {
			npToken = NowPlayingCenter.shared.subscribe { [weak self] s, artChanged in self?.receive(s, artChanged: artChanged) }
		}
		if lyricsToken == nil {
			lyricsToken = LyricsStore.shared.observe { [weak self] in self?.refresh() }
		}
		restartTimer()
	}

	public func stop() {
		timer?.invalidate()
		timer = nil
		NowPlayingCenter.shared.unsubscribe(npToken); npToken = nil
		LyricsStore.shared.removeObserver(lyricsToken); lyricsToken = nil
	}

	private func restartTimer() {
		timer?.invalidate()
		timer = nil
		// Tick only while music actually plays; slower on battery.
		guard npToken != nil, state.playing, LyricsWidgetSettings.lyricsOn else { return }
		let interval = (Power.onBattery || Power.lowPowerMode) ? 0.25 : 0.1
		let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
		t.tolerance = interval * 0.3
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	@objc private func settingsChanged() {
		expand(preferred: LyricsWidgetSettings.width)
		layoutContent()
		restartTimer()
		refresh()
	}

	// MARK: Data

	private func receive(_ s: NowPlaying, artChanged: Bool) {
		let wasPlaying = state.playing
		state = s
		if artChanged { artView.image = NowPlayingCenter.shared.artwork ?? NowPlayingCenter.appIcon(s.app) }
		if LyricsWidgetSettings.lyricsOn { LyricsStore.shared.update(for: s) }
		if wasPlaying != s.playing { restartTimer() }
		// Videos and web clips (no artist) aren't songs: step aside so Subtitles get the room.
		let isSong = s.hasContent && !s.artist.trimmingCharacters(in: .whitespaces).isEmpty
		if LyricsWidgetSettings.hideWhenIdle && !isSong {
			if s.hasContent {
				// A video or clip: keep a small ♪ so the full player is always one tap away.
				compact = true
				setCollapsed(false)
				setWidth(36, animated: false)
			} else {
				compact = false
				setCollapsed(true)
			}
		} else {
			compact = false
			let fits = expand(preferred: LyricsWidgetSettings.width)
			if !fits, s.playing, LyricsWidgetSettings.lyricsOn, LyricsWidgetSettings.fullPlayerWhenNoRoom, s.trackKey != autoOpenedFor {
				// The Pock bar is full: show this song's lyrics in the full player (once per song).
				autoOpenedFor = s.trackKey
				PurrPlayer.shared.show(lyrics: true)
			}
		}
		refresh()
	}

	/// Position never steps backwards except for a real seek (browser updates can lag a little).
	private func lyricTime() -> Double {
		let t = state.current
		if state.trackKey != clockKey || t < clock - 1.5 || t > clock + 3 {
			clockKey = state.trackKey
			clock = t
		} else {
			clock = max(clock, t)
		}
		return clock + LyricsStore.offset(for: state)
	}

	private func set(idle text: String) {
		line.set(text, lit: nil, second: "")
	}

	private func refresh() {
		if compact { line.set("♪", lit: nil, second: ""); return }
		guard state.hasContent else { set(idle: "♪  Nothing playing"); return }
		let title = NowPlayingCenter.cleanTitle(state.title)
		let artist = state.artist.isEmpty ? (NowPlayingCenter.appName(state.app) ?? "") : state.artist
		guard LyricsWidgetSettings.lyricsOn else {
			line.set(title, lit: nil, second: artist)
			return
		}
		let store = LyricsStore.shared
		if let l = store.line(at: lyricTime(), duration: state.duration) {
			let next = LyricsWidgetSettings.showNextLine ? l.next : ""
			line.set(l.current.isEmpty ? "♪" : l.current, lit: store.isSynced ? l.lit : nil, second: next)
		} else {
			let status = store.statusText
			line.set(title, lit: nil, second: status.isEmpty ? artist : status)
		}
		if !state.playing {
			line.secondColor = NSColor(white: 1, alpha: 0.4)
		} else {
			line.secondColor = NSColor(white: 1, alpha: 0.55)
		}
	}

	// MARK: Layout

	public override func layoutContent() {
		let h = bounds.height
		let showArt = LyricsWidgetSettings.showArtwork
		artView.isHidden = !showArt
		artView.frame = NSRect(x: 4, y: (h - 24) / 2, width: 24, height: 24)
		artView.isHidden = !showArt || compact
		let x: CGFloat = (showArt && !compact) ? 32 : 6
		line.frame = NSRect(x: x, y: 0, width: max(0, bounds.width - x - 6), height: h)
	}
}
