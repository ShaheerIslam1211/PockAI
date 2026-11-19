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

// MARK: - Purr full-bar player (from Purrbar), presented on top of PockAI's bar on demand

public final class PurrPlayer: NSObject, NSTouchBarDelegate {
    public static let shared = PurrPlayer()
    static let stripId = NSTouchBarItem.Identifier("local.pockai.purr.strip")
    static let minimizeId = NSTouchBarItem.Identifier("local.pockai.purr.minimize")
    static let playerId = NSTouchBarItem.Identifier("local.pockai.purr.player")
    static let volumeButtonId = NSTouchBarItem.Identifier("local.pockai.purr.volumebutton")
    static let volumeFullId = NSTouchBarItem.Identifier("local.pockai.purr.volumefull")
    static let backId = NSTouchBarItem.Identifier("local.pockai.purr.back")
    static let syncId = NSTouchBarItem.Identifier("local.pockai.purr.sync")
    static let lyricsId = NSTouchBarItem.Identifier("local.pockai.purr.lyrics")
    static let menuId = NSTouchBarItem.Identifier("local.pockai.purr.menu")
    // Width left for the main item next to the 44 pt menu/back button: measured from the real
    // Touch Bar (13" / 15" / 16") instead of the fixed 952 pt Purrbar used.
    static var barWidth: CGFloat { TouchBarMetrics.fullBarContentWidth(reserving: 44) }

    /// Open the full player automatically when a song starts (off: the Lyrics widget shows lyrics inline).
    public static var autoOpen: Bool {
        get { UserDefaults.standard.object(forKey: "pockai.purr.autoOpen") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "pockai.purr.autoOpen") }
    }
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]

    let bar = NSTouchBar()
    let player = PlayerView()
    private let minimizeButton = NSButton()
    private let volumeFull = VolumeFullView()
    private let volumeButton = NSButton()
    private let backButton = NSButton()
    private let syncView = SyncView()
    private var volumeMode = false
    private let lyricsButton = NSButton()
    private let menuButton = NSButton()
    private var menuOpen = false
    private var lyricTimer: Timer?
    private var lastVolumeSet = -1
    private var tickCount = 0
    private var lyricsOn = false
    private var lyrics: Lyrics?
    private var lyricsKey: String?
    private var lyricsStatus = ""
    private var lyricsLoading = false
    private var previewGapUntil = Date.distantPast
    private var previewIntroUntil = Date.distantPast
    private let spectrum = AudioSpectrum()
    private var lyricClock = 0.0
    private var lyricClockKey = ""

    // Position updates from browsers can land a fraction of a second behind the local estimate;
    // never let the lyrics clock step backwards unless it's a real seek.
    private func lyricTime() -> Double {
        let t = state.current
        if state.trackKey != lyricClockKey || t < lyricClock - 1.5 || t > lyricClock + 3 {
            lyricClockKey = state.trackKey
            lyricClock = t
        } else {
            lyricClock = max(lyricClock, t)
        }
        return lyricClock + lyricOffset
    }

    // MARK: battery saver

    private(set) var saving = false

    var batterySaver: BatterySaver {
        get { BatterySaver.current }
        set { BatterySaver.current = newValue; updatePowerMode() }
    }

    var hideWhenPaused: HideWhenPaused {
        get { HideWhenPaused.current }
        set { HideWhenPaused.current = newValue }
    }

    var keepAwake: KeepAwake {
        get { KeepAwake.current }
        set { KeepAwake.current = newValue }
    }
    private var awakeAssertion: IOPMAssertionID = 0
    private var lastAwakePing = Date.distantPast

    // Tells macOS the user is active (keeps the Touch Bar, and the screen, from dimming) while music plays,
    // up to the chosen time since the last real keyboard/trackpad input. That input clock isn't reset by this.
    private func keepTouchBarAwake() {
        guard keepAwake != .off, presented, state.playing, Date().timeIntervalSince(lastAwakePing) >= 20 else { return }
        let realIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if keepAwake != .playing && realIdle > Double(keepAwake.rawValue) { return }
        lastAwakePing = Date()
        IOPMAssertionDeclareUserActivity("Touch Bar Player: music playing" as CFString, kIOPMUserActiveLocal, &awakeAssertion)
    }

    var theme: Theme {
        get { Theme.current }
        set { Theme.current = newValue; player.theme = newValue }
    }

    var nightMode: NightMode {
        get { NightMode.current }
        set { NightMode.current = newValue; player.night = newValue.isOn }
    }

    private func startTimers() {
        guard presented else { return }
        tick?.invalidate()
        lyricTimer?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: saving ? 1.0 : 0.5, repeats: true) { [weak self] _ in self?.onTick() }
        lyricTimer = Timer.scheduledTimer(withTimeInterval: saving ? 0.25 : 0.1, repeats: true) { [weak self] _ in self?.updateLyricLine() }
        tick?.tolerance = saving ? 0.3 : 0.05
        lyricTimer?.tolerance = saving ? 0.08 : 0.02
    }

    private func updatePowerMode() {
        let on: Bool
        switch batterySaver {
        case .always: on = true
        case .off: on = false
        case .automatic: on = Power.onBattery || Power.lowPowerMode
        }
        guard on != saving else { return }
        saving = on
        spectrum.fps = on ? 12 : 24
        player.lowPower = on
        updateSpectrum()
        startTimers()
        onStateChange?()
    }

    // MARK: sync nudge (per song, remembered)

    private var offsetKey: String { "\(state.title)|\(state.artist)" }

    private var lyricOffset: Double {
        (UserDefaults.standard.dictionary(forKey: "lyricOffsets")?[offsetKey] as? Double) ?? 0
    }

    private func nudgeLyrics(_ delta: Double) {
        var all = UserDefaults.standard.dictionary(forKey: "lyricOffsets") ?? [:]
        let value = max(-10, min(10, ((all[offsetKey] as? Double) ?? 0) + delta))
        all[offsetKey] = value == 0 ? nil : value
        UserDefaults.standard.set(all, forKey: "lyricOffsets")
        syncView.show(value)
        translationNote = value == 0 ? "Lyrics back in original timing"
            : String(format: "Lyrics %.1f s %@", abs(value), value > 0 ? "earlier" : "later")
        translationNoteUntil = Date().addingTimeInterval(1.6)
        bumpMenu()
    }

    private var barsVisible = false

    // The audio tap runs only while the equaliser is on screen.
    private func updateSpectrum() {
        let want = barsVisible
        if want && !spectrum.running { _ = spectrum.start() }
        if !want && spectrum.running { spectrum.stop() }
    }

    private func gapVisible(_ on: Bool) {
        barsVisible = on
        updateSpectrum()
        guard on else { return }
        let ok = spectrum.running
        player.useRealLevels = ok
        guard ok else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.spectrum.running, !self.spectrum.gotSignal else { return }
            self.player.useFakeBars()
        }
    }

    private(set) var presented = false
    private var userMinimized = false
    private var lastActive = Date()
    private var state = NowPlaying()
    private var art: NSImage?
    private var artKey: String?
    private var palette = Palette.forApp(nil)
    private var tick: Timer?
    private var nowPlayingToken: UUID?
    private var lyricsToken: UUID?
    private var started = false
    private var lookReady = false
    public var onStateChange: (() -> Void)?

    public var isPresented: Bool { presented }

    private override init() { super.init() }

    /// Build the bar once (lazily, the first time the player is needed).
    private func startIfNeeded() {
        guard !started else { return }
        started = true
        bar.delegate = self
        applyItems()

        player.onCommand = { [weak self] c in self?.command(c) }
        player.onSeek = { t in NowPlayingCenter.shared.seek(to: t) }
        volumeFull.onChange = { [weak self] v in self?.setVolume(v); self?.bumpVolume() }
        volumeFull.onMute = { [weak self] in self?.toggleMute() }
        volumeFull.onTouch = { [weak self] in self?.bumpVolume() }
        syncView.onNudge = { [weak self] d in self?.nudgeLyrics(d) }
        player.volume.onChange = { [weak self] v in self?.setVolume(v) }
        player.volume.onMute = { [weak self] in self?.toggleMute() }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("local.pockai.purr.show"), object: nil, queue: .main) { [weak self] _ in self?.show() }
        dnc.addObserver(forName: .init("local.pockai.purr.hide"), object: nil, queue: .main) { [weak self] _ in self?.minimize(byUser: true) }
        dnc.addObserver(forName: .init("local.pockai.purr.lyrics"), object: nil, queue: .main) { [weak self] _ in self?.lyricsTapped() }
        dnc.addObserver(forName: .init("local.pockai.purr.menu"), object: nil, queue: .main) { [weak self] _ in self?.menuTapped() }
        dnc.addObserver(forName: .init("local.pockai.purr.volume"), object: nil, queue: .main) { [weak self] _ in self?.volumeButtonTapped() }
        dnc.addObserver(forName: .init("local.pockai.purr.peek"), object: nil, queue: .main) { [weak self] _ in self?.player.togglePeek() }
        dnc.addObserver(forName: .init("local.pockai.purr.nexttheme"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let all = Theme.allCases
            self.theme = all[((all.firstIndex(of: self.theme) ?? 0) + 1) % all.count]
        }
        dnc.addObserver(forName: .init("local.pockai.purr.previewintro"), object: nil, queue: .main) { [weak self] _ in
            self?.previewIntroUntil = Date().addingTimeInterval(5)
        }
        dnc.addObserver(forName: .init("local.pockai.purr.previewgap"), object: nil, queue: .main) { [weak self] _ in
            self?.previewGapUntil = Date().addingTimeInterval(5)
        }

        SystemVolume.observe { [weak self] in self?.refreshVolume() }
        player.onGapVisible = { [weak self] on in self?.gapVisible(on) }
        spectrum.onBands = { [weak self] b in self?.player.setLevels(b) }
        updatePowerMode()
        player.night = nightMode.isOn
        player.theme = theme
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updatePowerMode()
        }
    }

    public func shutdown() {
        if awakeAssertion != 0 { IOPMAssertionRelease(awakeAssertion); awakeAssertion = 0 }
        spectrum.stop()
        stopLive()
        if presented { SystemModalTouchBar.dismiss(bar) }
        presented = false
    }

    /// Listen to now-playing / lyrics and run the timers only while the player is on screen.
    private func startLive() {
        if nowPlayingToken == nil {
            nowPlayingToken = NowPlayingCenter.shared.subscribe { [weak self] state, artChanged in
                self?.receive(state, artChanged: artChanged)
            }
        }
        if lyricsToken == nil {
            lyricsToken = LyricsStore.shared.observe { [weak self] in self?.lyricsChanged() }
        }
        startTimers()
    }

    private func stopLive() {
        tick?.invalidate(); tick = nil
        lyricTimer?.invalidate(); lyricTimer = nil
        NowPlayingCenter.shared.unsubscribe(nowPlayingToken); nowPlayingToken = nil
        LyricsStore.shared.removeObserver(lyricsToken); lyricsToken = nil
    }

    // MARK: show / hide

    /// Present the full player over PockAI's bar. `lyrics: true` opens straight into lyrics.
    public func show(lyrics: Bool? = nil) {
        startIfNeeded()
        userMinimized = false
        if let lyrics, lyrics != lyricsOn { lyricsTapped() }
        if presented {
            // Something (e.g. the Pock bar re-presenting) may have covered us: bring the player back to the front.
            SystemModalTouchBar.present(bar, placement: 1)
            return
        }
        lastActive = Date()
        TouchBarMetrics.invalidate()
        applyItems()
        SystemModalTouchBar.present(bar, placement: 1)
        presented = true
        startLive()
        updateSpectrum()
        refreshVolume()
        onStateChange?()
    }

    public func minimize(byUser: Bool) {
        if byUser { userMinimized = true }
        guard presented else { return }
        SystemModalTouchBar.dismiss(bar)
        presented = false
        barsVisible = false
        updateSpectrum()
        stopLive()
        onStateChange?()
    }

    public func toggle() { presented ? minimize(byUser: true) : show() }

    @objc private func minimizeTapped() {
        menuOpen = false
        applyItems()
        minimize(byUser: true)
    }

    // MARK: side menu (minimise, lyrics, volume) behind one button

    private func applyItems() {
        if volumeMode {
            bar.defaultItemIdentifiers = [Self.backId, Self.volumeFullId]
            volumeFull.setWidth(Self.barWidth)
        } else {
            // The normal view has room for the volume slider; lyrics and the open menu use that room instead.
            bar.defaultItemIdentifiers = menuOpen
                ? [Self.menuId, Self.minimizeId, Self.lyricsId, Self.volumeButtonId] + (lyricsOn ? [Self.syncId] : []) + [Self.playerId]
                : [Self.menuId, Self.playerId]
            if menuOpen && lyricsOn { syncView.show(lyricOffset) }
            player.showsVolume = !menuOpen && !lyricsOn
            player.setWidth(menuOpen ? Self.barWidth - 156 - (lyricsOn ? SyncView.width + 8 : 0) : Self.barWidth)
        }
        menuButton.image = NSImage(systemSymbolName: menuOpen ? "xmark" : "line.3.horizontal", accessibilityDescription: "Menu")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        bumpMenu()
    }

    private func bumpMenu() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closeMenu), object: nil)
        if menuOpen { perform(#selector(closeMenu), with: nil, afterDelay: 6) }
    }

    @objc private func closeMenu() {
        guard menuOpen else { return }
        menuOpen = false
        applyItems()
    }

    @objc private func menuTapped() {
        menuOpen.toggle()
        applyItems()
    }

    // MARK: full-bar volume

    @objc private func volumeButtonTapped() {
        menuOpen = false
        volumeMode = true
        refreshVolume()
        applyItems()
        bumpVolume()
    }

    @objc private func closeVolume() {
        guard volumeMode else { return }
        volumeMode = false
        applyItems()
    }

    private func bumpVolume() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(closeVolume), object: nil)
        if volumeMode { perform(#selector(closeVolume), with: nil, afterDelay: 4) }
    }

    // MARK: data

    private func receive(_ np: NowPlaying, artChanged: Bool) {
        let old = state
        var lookChanged = old.app != np.app || !lookReady || artChanged
        if artChanged || np.artKey != artKey {
            art = NowPlayingCenter.shared.artwork
            artKey = np.artKey
            lookChanged = true
        }
        state = np

        // Colours, artwork and the strip button only change with the cover or the app, not every position update.
        if lookChanged {
            lookReady = true
            palette = art.flatMap(Palette.fromArt) ?? Palette.forApp(np.app)
            player.setPalette(palette)
            volumeFull.palette = palette
            updateLyricsButton()
            player.setArt(art ?? placeholder())
        }
        player.setText(np.hasContent ? cleanTitle(np.title) : "Nothing playing",
                       np.artist.isEmpty ? (appName(np.app) ?? "") : np.artist)
        player.setPlaying(np.playing)
        player.setProgress(np.current, duration: np.duration)
        if lyricsOn && old.trackKey != np.trackKey { loadLyricsIfNeeded() }
        updateLyricLine()

        if np.playing { lastActive = Date() }
        let begun = np.playing && (!old.playing || old.trackKey != np.trackKey)
        if begun && Self.autoOpen && !userMinimized && !presented { show() }
    }

    private func onTick() {
        if state.playing { player.setProgress(state.current, duration: state.duration) }
        tickCount += 1
        keepTouchBarAwake()
        if tickCount % 20 == 0 {
            updatePowerMode()
            player.night = nightMode.isOn
        }
        // Idle for two minutes: step aside, and let the next song bring the player back.
        let hideAfter = Double(hideWhenPaused.rawValue)
        if hideAfter > 0 && presented && !state.playing && Date().timeIntervalSince(lastActive) > hideAfter {
            minimize(byUser: false)
            userMinimized = false
        }
    }

    private func command(_ c: Cmd) {
        lastActive = Date()
        NowPlayingCenter.shared.sendRaw("cmd \(c.rawValue)")
        if c == .toggle { state.playing.toggle(); player.setPlaying(state.playing) }
    }

    private func placeholder() -> NSImage {
        let p = palette
        return NSImage(size: NSSize(width: 60, height: 60), flipped: false) { r in
            NSGradient(starting: p.accent, ending: p.second)?.draw(in: r, angle: -45)
            let cfg = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold).applying(.init(paletteColors: [.white]))
            if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let s = note.size
                note.draw(in: NSRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    private func cleanTitle(_ t: String) -> String { NowPlayingCenter.cleanTitle(t) }

    private var isSong: Bool { !state.artist.trimmingCharacters(in: .whitespaces).isEmpty }

    private func appName(_ id: String?) -> String? { NowPlayingCenter.appName(id) }

    // MARK: lyrics

    @objc private func lyricsTapped() {
        lyricsOn.toggle()
        menuOpen = false
        applyItems()
        player.setLyricsMode(lyricsOn)
        updateLyricsButton()
        if lyricsOn { loadLyricsIfNeeded() }
        updateLyricLine()
    }

    private func updateLyricsButton() {
        lyricsButton.bezelColor = lyricsOn ? palette.accent : NSColor(white: 0.22, alpha: 1)
        lyricsButton.contentTintColor = lyricsOn ? palette.onAccent : .white
    }

    private var translations: [String] = []
    private var translationNote = ""
    private var translationNoteUntil = Date.distantPast
    private var translationKey: String?
    private var downloadWindow: NSWindow?

    var translateTarget: TranslateTarget {
        get { TranslateTarget.current }
        set {
            TranslateTarget.current = newValue
            translationKey = nil
            translations = []
            translateIfNeeded()
        }
    }

    private func translateIfNeeded() {
        guard let l = lyrics, let key = lyricsKey, translateTarget != .off else { translations = []; return }
        let tag = key + "|" + translateTarget.rawValue
        guard tag != translationKey else { return }
        translationKey = tag
        translations = []
        let target = translateTarget
        guard #available(macOS 15.0, *) else {
            // Apple's on-device translator arrived in macOS 15.
            translationNote = "Lyrics translation needs macOS 15 or newer"
            translationNoteUntil = Date().addingTimeInterval(6)
            return
        }
        Task { @MainActor in
            let outcome = await LyricsTranslator.translate(l, to: target)
            guard self.translationKey == tag else { return }
            switch outcome {
            case .lines(let lines):
                self.translations = lines
            case .note(let text):
                self.translationNote = text
                self.translationNoteUntil = Date().addingTimeInterval(6)
            case .needsDownload(let src, let dst):
                self.askToDownload(src, dst) { [weak self] in
                    self?.translationKey = nil
                    self?.translateIfNeeded()
                }
            }
        }
    }

    @available(macOS 15.0, *)
    private func askToDownload(_ src: Locale.Language, _ dst: Locale.Language, then: @escaping () -> Void) {
        guard downloadWindow == nil else { return }
        let view = TranslationDownloadView(configuration: .init(source: src, target: dst)) { [weak self] in
            self?.downloadWindow?.close()
            self?.downloadWindow = nil
            then()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Translate Lyrics"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        downloadWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    var lyricsScript: LyricsScript {
        get { LyricsScript.current }
        set {
            LyricsScript.current = newValue
            lyricsKey = nil
            LyricsStore.shared.reload()
        }
    }

    private func loadLyricsIfNeeded() {
        LyricsStore.shared.update(for: state)
        lyricsChanged()
    }

    /// Shared store finished (or started) a search.
    private func lyricsChanged() {
        let store = LyricsStore.shared
        let changed = store.trackKey != lyricsKey
        lyricsKey = store.trackKey
        lyrics = store.lyrics
        lyricsLoading = store.status == .searching
        lyricsStatus = store.statusText
        if changed { translateIfNeeded() }
        updateLyricLine()
    }

    private func updateLyricLine() {
        guard lyricsOn else { return }
        if !state.playing && state.hasContent {
            player.setOverlay("Paused")
        } else {
            player.setOverlay(nil)
        }
        let t = lyricTime()
        var mode = PlayerView.Center.lyric
        if let (start, end) = lyrics?.gap(at: t) {
            // Song opens with music: title card for its first 10 s (or until the singing, if sooner), then live bars.
            mode = start == 0 && t < 10 ? .intro : .bars
        } else if lyrics == nil && state.hasContent {
            // Searching or none found: the song intro for its first 10 s, then the equaliser; a small badge says which.
            mode = t < 10 && isSong ? .intro : .bars
        }
        player.setBadge(lyrics != nil ? .none : lyricsLoading ? .searching : .noLyrics)
        if Date() < previewGapUntil { mode = .bars }
        if Date() < previewIntroUntil { mode = .intro }
        if mode == .intro {
            player.setIntroText(cleanTitle(state.title), state.artist.isEmpty ? (appName(state.app) ?? "") : state.artist)
        }
        player.setCenter(mode)
        if let l = lyrics {
            let (a, lit, _) = l.at(t, duration: state.duration)
            var translation = ""
            if Date() < translationNoteUntil {
                translation = translationNote
            } else if let i = l.index(at: t, duration: state.duration), i < translations.count, !lyrics!.lines[i].text.isEmpty {
                translation = translations[i]
            }
            player.setLyrics(a, lit: lit, translation: translation)
        } else {
            player.setLyrics(lyricsStatus, lit: (lyricsStatus as NSString).length)
        }
    }

    // MARK: volume

    private func refreshVolume() {
        let (level, muted) = SystemVolume.read()
        volumeFull.set(level: level, muted: muted)
        player.volume.set(level: level, muted: muted)
    }

    private func setVolume(_ v: Int) {
        guard v != lastVolumeSet else { return }
        lastVolumeSet = v
        SystemVolume.set(level: v)
        volumeFull.set(level: v, muted: v == 0)
        player.volume.set(level: v, muted: v == 0)
    }

    private func toggleMute() {
        SystemVolume.setMuted(!SystemVolume.read().muted)
        lastVolumeSet = -1
        refreshVolume()
    }

    private func styleSmall(_ b: NSButton, symbol: String, label: String, action: Selector) {
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        b.imagePosition = .imageOnly
        b.bezelColor = NSColor(white: 0.22, alpha: 1)
        b.contentTintColor = .white
        b.target = self
        b.action = action
        if b.constraints.isEmpty { b.widthAnchor.constraint(equalToConstant: 44).isActive = true }
    }

    // MARK: NSTouchBarDelegate

    public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case Self.minimizeId:
            let item = NSCustomTouchBarItem(identifier: id)
            minimizeButton.bezelStyle = .rounded
            minimizeButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Minimise")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
            minimizeButton.imagePosition = .imageOnly
            minimizeButton.bezelColor = NSColor(white: 0.22, alpha: 1)
            minimizeButton.contentTintColor = .white
            minimizeButton.target = self
            minimizeButton.action = #selector(minimizeTapped)
            minimizeButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
            item.view = minimizeButton
            return item
        case Self.playerId:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = player
            return item
        case Self.menuId:
            let item = NSCustomTouchBarItem(identifier: id)
            menuButton.bezelStyle = .rounded
            menuButton.imagePosition = .imageOnly
            menuButton.bezelColor = NSColor(white: 0.22, alpha: 1)
            menuButton.contentTintColor = .white
            menuButton.target = self
            menuButton.action = #selector(menuTapped)
            menuButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
            item.view = menuButton
            return item
        case Self.lyricsId:
            let item = NSCustomTouchBarItem(identifier: id)
            lyricsButton.bezelStyle = .rounded
            lyricsButton.image = NSImage(systemSymbolName: "quote.bubble.fill", accessibilityDescription: "Lyrics")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
            lyricsButton.imagePosition = .imageOnly
            lyricsButton.target = self
            lyricsButton.action = #selector(lyricsTapped)
            lyricsButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
            updateLyricsButton()
            item.view = lyricsButton
            return item
        case Self.volumeButtonId:
            let item = NSCustomTouchBarItem(identifier: id)
            styleSmall(volumeButton, symbol: "speaker.wave.2.fill", label: "Volume", action: #selector(volumeButtonTapped))
            item.view = volumeButton
            return item
        case Self.backId:
            let item = NSCustomTouchBarItem(identifier: id)
            styleSmall(backButton, symbol: "chevron.left", label: "Back", action: #selector(closeVolume))
            item.view = backButton
            return item
        case Self.syncId:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = syncView
            return item
        case Self.volumeFullId:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = volumeFull
            return item
        default:
            return nil
        }
    }
}
