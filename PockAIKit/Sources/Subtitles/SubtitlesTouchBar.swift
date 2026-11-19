import AppKit
import PockKit

/// Subtitles in the Pock bar. Tap: full-width subtitles. Long press: hide / show (a small CC button stays).
public final class SubtitlesTouchBarView: TouchView {

	private let line = LineView(frame: .zero)
	private let cc = NSImageView()
	private var token: UUID?

	public init() {
		super.init(width: SubtitleSettings.width, collapsed: SubtitleSettings.visible && SubtitleSettings.hideWhenEmpty)
		layer?.cornerRadius = 6
		layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
		cc.image = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: "Subtitles")?
			.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
		cc.contentTintColor = NSColor(white: 1, alpha: 0.7)
		addSubview(cc)
		line.mainFont = .systemFont(ofSize: 13, weight: .semibold)
		line.secondFont = .systemFont(ofSize: 11, weight: .semibold)
		line.secondColor = .white
		line.alignment = .center
		addSubview(line)
		onTap = { [weak self] in
			guard SubtitleSettings.visible else { SubtitleSettings.visible = true; return }
			_ = self
			SubtitlesBar.toggle()
		}
		onLongPress = { SubtitleSettings.visible.toggle() }
		NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SubtitleSettings.didChange, object: nil)
	}

	required init?(coder: NSCoder) { super.init(coder: coder) }

	deinit {
		NotificationCenter.default.removeObserver(self)
		stop()
	}

	public func start() {
		guard token == nil else { return }
		token = SubtitleCenter.shared.observe { [weak self] in self?.refresh() }
	}

	public func stop() {
		SubtitleCenter.shared.removeObserver(token)
		token = nil
	}

	@objc private func refresh() {
		let center = SubtitleCenter.shared
		let visible = SubtitleSettings.visible
		let empty = center.text.isEmpty
		if !visible {
			// Hidden: shrink to a CC button you can tap to bring them back.
			setWidth(40)
			setCollapsed(false)
			line.isHidden = true
			cc.contentTintColor = NSColor(white: 1, alpha: 0.45)
		} else {
			if SubtitleSettings.hideWhenEmpty && empty {
				setCollapsed(true)
			} else if !expand(preferred: SubtitleSettings.width), !empty, SubtitleSettings.autoFullBar {
				// The Pock bar is full: show the captions over the whole Touch Bar instead.
				SubtitlesBar.showAutomatically()
			}
			line.isHidden = false
			cc.contentTintColor = NSColor(white: 1, alpha: 0.7)
			let parts = center.text.components(separatedBy: "\n")
			if parts.count >= 2 {
				line.set(parts[0], lit: nil, second: parts[1...].joined(separator: " "))
			} else {
				line.set(empty ? "CC  waiting for subtitles…" : center.text, lit: nil, second: "")
			}
			line.litColor = empty ? NSColor(white: 1, alpha: 0.45) : .white
		}
		layoutContent()
	}

	public override func layoutContent() {
		let h = bounds.height
		cc.frame = NSRect(x: 6, y: (h - 20) / 2, width: 24, height: 20)
		line.frame = NSRect(x: 32, y: 0, width: max(0, bounds.width - 38), height: h)
	}
}

/// Full-width subtitles over the whole Touch Bar (big, readable). Tap anywhere to go back.
public final class SubtitlesBar: PKTouchBarController {

	private static let contentId = NSTouchBarItem.Identifier("com.pockai.subtitles.full")
	private static weak var current: SubtitlesBar?
	private let line = LineView(frame: .zero)
	private let content = TouchView(width: TouchBarMetrics.fullBarContentWidth())
	private var token: UUID?

	private var automatic = false
	private var idleWork: DispatchWorkItem?
	/// The user closed the automatic bar: don't reopen it until captions stop and start again.
	private static var suppressedUntilQuiet = false

	public static func toggle() {
		if let current { current.dismiss(); return }
		open(automatic: false)
	}

	static func showAutomatically() {
		guard current == nil, !suppressedUntilQuiet else { return }
		// Never cover something you opened yourself (AI tools, a game, the clipboard…).
		if let nav = SubtitlesBar().mainNavigationController, nav.childControllers.count > 1 { return }
		open(automatic: true)
	}

	private static func open(automatic: Bool) {
		let bar = SubtitlesBar()
		bar.automatic = automatic
		current = bar
		if let nav = bar.mainNavigationController {
			nav.popToRootController()
			nav.push(bar)
		} else { bar.present() }
	}

	public override func makeTouchBar() -> NSTouchBar? {
		let bar = NSTouchBar()
		bar.delegate = self
		bar.defaultItemIdentifiers = [Self.contentId]
		return bar
	}

	public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
		guard identifier == Self.contentId else { return nil }
		let item = NSCustomTouchBarItem(identifier: identifier)
		content.layer?.backgroundColor = NSColor.black.cgColor
		line.frame = NSRect(x: 0, y: 0, width: content.currentWidth, height: 30)
		line.autoresizingMask = [.width, .height]
		line.mainFont = .systemFont(ofSize: 15, weight: .bold)
		line.secondFont = .systemFont(ofSize: 12, weight: .bold)
		line.secondColor = .white
		line.alignment = .center
		content.addSubview(line)
		content.onTap = { [weak self] in
			if self?.automatic == true { SubtitlesBar.suppressedUntilQuiet = true }
			self?.dismiss()
		}
		content.onLongPress = { [weak self] in SubtitleSettings.visible = false; self?.dismiss() }
		item.view = content
		token = SubtitleCenter.shared.observe { [weak self] in self?.refresh() }
		return item
	}

	private func refresh() {
		let text = SubtitleCenter.shared.text
		idleWork?.cancel()
		if text.isEmpty {
			// Captions stopped: close an automatic bar after a short pause.
			let work = DispatchWorkItem { [weak self] in
				SubtitlesBar.suppressedUntilQuiet = false
				if self?.automatic == true { self?.dismiss() }
			}
			idleWork = work
			DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
		}
		let parts = text.components(separatedBy: "\n")
		if parts.count >= 2 {
			line.set(parts[0], lit: nil, second: parts[1...].joined(separator: " "))
		} else {
			line.set(text.isEmpty ? "…" : text, lit: nil, second: "")
		}
	}

	public override func dismiss() {
		idleWork?.cancel()
		SubtitleCenter.shared.removeObserver(token)
		token = nil
		super.dismiss()
		if Self.current === self { Self.current = nil }
	}
}
