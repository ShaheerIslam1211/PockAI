import AppKit

/// The Purrbar settings (theme, lyrics script, translation, battery saver…) as a menu for PockAI's menu bar.
extension PurrPlayer {

    public func makeSettingsMenu() -> NSMenu {
        let m = NSMenu(title: "Lyrics & Player")
        m.autoenablesItems = false
        let open = m.addItem(withTitle: presented ? "Hide Full Player" : "Show Full Player on Touch Bar", action: #selector(menuTogglePlayer), keyEquivalent: "")
        open.target = self
        let auto = m.addItem(withTitle: "Open Full Player When Music Starts", action: #selector(menuToggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = Self.autoOpen ? .on : .off
        m.addItem(.separator())
        m.addItem(submenu("Theme", Theme.allCases.map { ($0.title, $0.rawValue, $0 == theme) }, #selector(menuTheme(_:))))
        m.addItem(submenu("Lyrics Script", LyricsScript.allCases.map { ($0.title, $0.rawValue, $0 == lyricsScript) }, #selector(menuScript(_:))))
        m.addItem(submenu("Translate Lyrics", TranslateTarget.allCases.map { ($0.title, $0.rawValue, $0 == translateTarget) }, #selector(menuTranslate(_:))))
        m.addItem(.separator())
        m.addItem(submenu("Battery Saver", BatterySaver.allCases.map { ($0.title, $0.rawValue, $0 == batterySaver) }, #selector(menuSaver(_:))))
        m.addItem(submenu("Night Mode", NightMode.allCases.map { ($0.title, $0.rawValue, $0 == nightMode) }, #selector(menuNight(_:))))
        m.addItem(submenu("Hide Player When Paused", HideWhenPaused.allCases.map { ($0.title, "\($0.rawValue)", $0 == hideWhenPaused) }, #selector(menuHide(_:))))
        m.addItem(submenu("Keep Touch Bar Awake", KeepAwake.allCases.map { ($0.title, "\($0.rawValue)", $0 == keepAwake) }, #selector(menuAwake(_:))))
        return m
    }

    private func submenu(_ title: String, _ options: [(String, String, Bool)], _ action: Selector) -> NSMenuItem {
        let sub = NSMenu(title: title)
        for (name, value, on) in options {
            let item = sub.addItem(withTitle: name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = on ? .on : .off
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc private func menuTogglePlayer() { toggle() }
    @objc private func menuToggleAuto() { Self.autoOpen.toggle() }
    @objc private func menuTheme(_ s: NSMenuItem) { if let v = s.representedObject as? String, let o = Theme(rawValue: v) { theme = o } }
    @objc private func menuScript(_ s: NSMenuItem) { if let v = s.representedObject as? String, let o = LyricsScript(rawValue: v) { lyricsScript = o } }
    @objc private func menuTranslate(_ s: NSMenuItem) { if let v = s.representedObject as? String, let o = TranslateTarget(rawValue: v) { translateTarget = o } }
    @objc private func menuSaver(_ s: NSMenuItem) { if let v = s.representedObject as? String, let o = BatterySaver(rawValue: v) { batterySaver = o } }
    @objc private func menuNight(_ s: NSMenuItem) { if let v = s.representedObject as? String, let o = NightMode(rawValue: v) { nightMode = o } }
    @objc private func menuHide(_ s: NSMenuItem) { if let v = (s.representedObject as? String).flatMap(Int.init), let o = HideWhenPaused(rawValue: v) { hideWhenPaused = o } }
    @objc private func menuAwake(_ s: NSMenuItem) { if let v = (s.representedObject as? String).flatMap(Int.init), let o = KeepAwake(rawValue: v) { keepAwake = o } }
}
