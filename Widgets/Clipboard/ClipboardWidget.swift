import AppKit
import Carbon
import PockKit
import PockAIKit

/// Clipboard history on the Touch Bar: the last 15 things you copied (text only, kept in memory only).
/// Tap 📋 → your recent copies take over the bar; tap one to paste it into the front app.
final class ClipboardWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.Clipboard"
	var customizationLabel: String = "Clipboard History"
	var view: NSView!

	private let button = TouchView(width: 64)
	private let icon = NSImageView()
	private let count = NSTextField(labelWithString: "")

	required override init() {
		super.init()
		button.layer?.cornerRadius = 6
		button.layer?.backgroundColor = PAIColors.chip.cgColor
		icon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")?
			.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
		icon.contentTintColor = .white
		icon.frame = NSRect(x: 8, y: 5, width: 20, height: 20)
		count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
		count.textColor = .white
		count.frame = NSRect(x: 32, y: 7, width: 30, height: 16)
		button.addSubview(icon)
		button.addSubview(count)
		button.onTap = { ClipboardBar.open() }
		button.onLongPress = { ClipboardHistory.shared.clear() }
		view = button
		ClipboardHistory.shared.onChange = { [weak self] in self?.refresh() }
		ClipboardHistory.shared.start()
		refresh()
	}

	private func refresh() {
		count.stringValue = "\(ClipboardHistory.shared.items.count)"
	}

	deinit { ClipboardHistory.shared.onChange = nil }
}

/// Watches the pasteboard (once a second, only the cheap change counter) and keeps recent text.
final class ClipboardHistory {
	static let shared = ClipboardHistory()
	private(set) var items: [String] = []
	var onChange: (() -> Void)?
	private var timer: Timer?
	private var lastChange = NSPasteboard.general.changeCount
	private var limit: Int { min(50, max(5, UserDefaults.standard.object(forKey: "pockai.clip.limit") as? Int ?? 15)) }
	private var settingsObserver: NSObjectProtocol?

	init() {
		settingsObserver = NotificationCenter.default.addObserver(forName: PockAIWidgetSettingsDidChange, object: nil, queue: .main) { [weak self] note in
			guard let self else { return }
			if note.object as? String == "pockai.clip.clear" { self.clear(); return }
			if self.items.count > self.limit { self.items.removeLast(self.items.count - self.limit); self.onChange?() }
		}
	}
	/// Password managers mark secrets with these; never record them.
	private let concealed: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]

	func start() {
		guard timer == nil else { return }
		let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
		t.tolerance = 0.3
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	func clear() {
		items.removeAll()
		onChange?()
	}

	private func poll() {
		let board = NSPasteboard.general
		guard board.changeCount != lastChange else { return }
		lastChange = board.changeCount
		let types = Set((board.types ?? []).map(\.rawValue))
		guard types.isDisjoint(with: concealed),
			  let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !text.isEmpty, text.count < 20_000 else { return }
		items.removeAll { $0 == text }
		items.insert(text, at: 0)
		if items.count > limit { items.removeLast(items.count - limit) }
		onChange?()
	}

	/// Put `text` on the clipboard and press ⌘V in the front app.
	func paste(_ text: String) {
		let board = NSPasteboard.general
		board.clearContents()
		board.setString(text, forType: .string)
		lastChange = board.changeCount
		guard UserDefaults.standard.object(forKey: "pockai.clip.paste") as? Bool ?? true, AXIsProcessTrusted() else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
			let source = CGEventSource(stateID: .combinedSessionState)
			for down in [true, false] {
				let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
				e?.flags = .maskCommand
				e?.post(tap: .cghidEventTap)
			}
		}
	}
}

/// Full-bar list of recent copies.
final class ClipboardBar: PKTouchBarController {
	private static let closeId = NSTouchBarItem.Identifier("com.pockai.clipboard.close")
	private static let listId = NSTouchBarItem.Identifier("com.pockai.clipboard.list")
	private static weak var current: ClipboardBar?

	static func open() {
		current?.dismiss()
		let bar = ClipboardBar()
		current = bar
		if let nav = bar.mainNavigationController {
			// Replace any other full-bar screen instead of stacking on top of it (stacked ones were never freed).
			nav.popToRootController()
			nav.push(bar)
		} else { bar.present() }
	}

	override func makeTouchBar() -> NSTouchBar? {
		let bar = NSTouchBar()
		bar.delegate = self
		bar.defaultItemIdentifiers = [Self.closeId, Self.listId]
		return bar
	}

	@objc func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
		let item = NSCustomTouchBarItem(identifier: identifier)
		if identifier == Self.closeId {
			let b = PAIButton(symbol: "xmark", target: self, action: #selector(close))
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
			item.view = b
			return item
		}
		guard identifier == Self.listId else { return nil }
		let width = TouchBarMetrics.fullBarContentWidth(reserving: 44)
		let items = ClipboardHistory.shared.items
		var x: CGFloat = 0
		let doc = NSView()
		if items.isEmpty {
			let label = NSTextField(labelWithString: "Nothing copied yet — copy some text and it shows up here.")
			label.textColor = NSColor(white: 1, alpha: 0.6)
			label.font = .systemFont(ofSize: 13)
			label.frame = NSRect(x: 8, y: 6, width: width - 16, height: 18)
			doc.addSubview(label)
			x = width
		}
		let clear = PAIButton(symbol: "trash", target: self, action: #selector(clearAll))
		clear.frame = NSRect(x: x, y: 0, width: 44, height: 30)
		if !items.isEmpty { doc.addSubview(clear); x += 50 }
		for (index, text) in items.enumerated() {
			let title = text.replacingOccurrences(of: "\n", with: " ⏎ ")
			let b = PAIButton(symbol: nil, title: String(title.prefix(40)) + (title.count > 40 ? "…" : ""), target: self, action: #selector(pick(_:)))
			b.tag = index
			b.lineBreakMode = .byTruncatingTail
			let w = min(260, max(60, ceil(b.intrinsicContentSize.width) + 16))
			b.frame = NSRect(x: x, y: 0, width: w, height: 30)
			doc.addSubview(b)
			x += w + 6
		}
		doc.frame = NSRect(x: 0, y: 0, width: max(x, width), height: 30)
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
		scroll.drawsBackground = false
		scroll.hasHorizontalScroller = false
		scroll.documentView = doc
		scroll.translatesAutoresizingMaskIntoConstraints = false
		scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
		item.view = scroll
		return item
	}

	@objc private func pick(_ sender: NSButton) {
		let items = ClipboardHistory.shared.items
		guard items.indices.contains(sender.tag) else { return }
		let text = items[sender.tag]
		dismiss()
		ClipboardHistory.shared.paste(text)
	}

	@objc private func clearAll() {
		ClipboardHistory.shared.clear()
		dismiss()
	}

	@objc private func close() { dismiss() }
}
