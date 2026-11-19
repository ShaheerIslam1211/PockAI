import AppKit

/// Base view for PockAI widgets: tap / long-press / swipe on the Touch Bar,
/// plus a width that can grow, shrink, or collapse to zero (the widget "disappears").
open class TouchView: NSView {

	public var onTap: (() -> Void)?
	public var onLongPress: (() -> Void)?
	public var onSwipeLeft: (() -> Void)?
	public var onSwipeRight: (() -> Void)?

	public var longPressDelay: TimeInterval = 0.5

	private var widthConstraint: NSLayoutConstraint?
	public private(set) var currentWidth: CGFloat = 0
	public private(set) var collapsed = false

	private var startX: CGFloat?
	private var longPressFired = false
	private var longPressTimer: Timer?

	public init(width: CGFloat, collapsed startCollapsed: Bool = false) {
		super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
		currentWidth = width
		collapsed = startCollapsed
		alphaValue = startCollapsed ? 0 : 1
		allowedTouchTypes = [.direct]
		wantsLayer = true
		translatesAutoresizingMaskIntoConstraints = false
		widthConstraint = widthAnchor.constraint(equalToConstant: startCollapsed ? 0 : width)
		widthConstraint?.priority = .defaultHigh + 1
		widthConstraint?.isActive = true
		heightAnchor.constraint(equalToConstant: 30).isActive = true
	}

	required public init?(coder: NSCoder) {
		super.init(coder: coder)
	}

	open override var intrinsicContentSize: NSSize {
		NSSize(width: collapsed ? 0 : currentWidth, height: 30)
	}

	/// Change the width (animated on the Touch Bar).
	public func setWidth(_ width: CGFloat, animated: Bool = true) {
		currentWidth = max(0, width)
		applyWidth(animated: animated)
	}

	/// Smallest width worth showing; below this the widget stays collapsed.
	public var minimumUsefulWidth: CGFloat = 90

	/// Free room on the live Touch Bar for this widget: the bar's width minus every other item.
	/// nil when not on a bar yet.
	public var availableWidth: CGFloat? {
		// Scrollable bar: there's always room; keep the widget no wider than what's visible at once.
		if superview?.identifier?.rawValue == "pockai.scrollStack" {
			guard let visible = enclosingScrollView?.frame.width, visible > 100 else { return nil }
			return max(0, visible - 80)
		}
		guard let container = superview, let bar = container.superview, bar.bounds.width > 100 else { return nil }
		let others = bar.subviews.filter { $0 !== container }
		let used = others.reduce(CGFloat(0)) { $0 + $1.frame.width }
		let visibleCount = others.filter { $0.frame.width > 0 }.count
		return max(0, bar.bounds.width - used - CGFloat(visibleCount + 1) * 8)
	}

	/// Expand to `preferred`, or less if the bar is crowded. Returns false when there is no room at all.
	@discardableResult
	public func expand(preferred: CGFloat) -> Bool {
		let room = availableWidth ?? preferred
		let width = min(preferred, room)
		guard width >= minimumUsefulWidth else {
			setCollapsed(true)
			return false
		}
		if abs(width - currentWidth) > 1 { currentWidth = width }
		let appearing = collapsed
		if collapsed { setCollapsed(false) } else { applyWidth(animated: false) }
		// In the scrollable bar, bring a widget that just got content (subtitles, a new song) into view.
		if appearing, superview?.identifier?.rawValue == "pockai.scrollStack" {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
				guard let self else { return }
				self.scrollToVisible(self.bounds)
			}
		}
		return true
	}

	/// Collapse to zero width (the widget leaves its slot empty) or come back.
	public func setCollapsed(_ value: Bool, animated: Bool = true) {
		guard value != collapsed else { return }
		collapsed = value
		applyWidth(animated: animated)
	}

	private func applyWidth(animated: Bool) {
		let target = collapsed ? 0 : currentWidth
		alphaValue = collapsed ? 0 : 1
		widthConstraint?.constant = target
		invalidateIntrinsicContentSize()
		layoutContent()
		pushLayoutToTouchBar()
	}

	/// The Touch Bar is drawn by a separate system process; a size change inside an item only reaches it
	/// once the whole bar re-lays out and redraws, so ask for that explicitly.
	/// Posted when a PockAI widget changes size; the host app re-presents its bar so the change shows.
	public static let sizeDidChange = Notification.Name("pockai.widget.sizeDidChange")

	public func pushLayoutToTouchBar() {
		NotificationCenter.default.post(name: TouchView.sizeDidChange, object: self)
		guard let window else { return }
		var node: NSView? = superview
		while let n = node {
			n.invalidateIntrinsicContentSize()
			n.needsLayout = true
			node = n.superview
		}
		window.contentView?.layoutSubtreeIfNeeded()
		window.contentView?.needsDisplay = true
		window.displayIfNeeded()
	}

	open override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		// Size may have changed while we weren't on the bar.
		if window != nil { DispatchQueue.main.async { [weak self] in self?.pushLayoutToTouchBar() } }
	}

	/// Override to lay out subviews for `bounds`.
	open func layoutContent() {}

	open override func layout() {
		super.layout()
		layoutContent()
		if ProcessInfo.processInfo.environment["PKAI_DEBUG"] != nil { dumpAncestors() }
	}

	private func dumpAncestors() {
		var node: NSView? = self
		var depth = 0
		while let n = node, depth < 12 {
			NSLog("[PKAI] depth \(depth) \(type(of: n)) frame \(n.frame) subviews \(n.subviews.count): \(n.subviews.map { "\(type(of: $0))@\(Int($0.frame.minX))w\(Int($0.frame.width))" }.prefix(14))")
			node = n.superview
			depth += 1
		}
		NSLog("[PKAI] window \(String(describing: window?.frame)) self alpha \(alphaValue) hidden \(isHidden) layer \(String(describing: layer)) opacity \(layer?.opacity ?? -1) bounds \(bounds) wantsLayer \(wantsLayer) canDraw \(canDraw)")
	}

	// MARK: Touches

	open override func touchesBegan(with event: NSEvent) {
		super.touchesBegan(with: event)
		guard let touch = event.touches(matching: .began, in: self).first else { return }
		startX = touch.location(in: self).x
		longPressFired = false
		longPressTimer?.invalidate()
		guard onLongPress != nil else { return }
		longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDelay, repeats: false) { [weak self] _ in
			self?.longPressFired = true
			self?.onLongPress?()
		}
	}

	open override func touchesEnded(with event: NSEvent) {
		super.touchesEnded(with: event)
		longPressTimer?.invalidate()
		longPressTimer = nil
		defer { startX = nil }
		guard !longPressFired, let startX, let touch = event.touches(matching: .ended, in: self).first else { return }
		let dx = touch.location(in: self).x - startX
		if dx < -30, let left = onSwipeLeft {
			left()
		} else if dx > 30, let right = onSwipeRight {
			right()
		} else if abs(dx) <= 30 {
			onTap?()
		}
	}

	open override func touchesCancelled(with event: NSEvent) {
		super.touchesCancelled(with: event)
		longPressTimer?.invalidate()
		longPressTimer = nil
		startX = nil
	}

	deinit {
		longPressTimer?.invalidate()
	}
}

/// Rounded Touch Bar style button with an SF Symbol, used across PockAI widgets.
public func PAIButton(symbol: String?, title: String? = nil, color: NSColor? = nil, target: AnyObject?, action: Selector?) -> NSButton {
	let button = NSButton(title: title ?? "", target: target, action: action)
	button.bezelStyle = .rounded
	if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
		button.image = image.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
		button.imagePosition = (title?.isEmpty ?? true) ? .imageOnly : .imageLeading
	}
	if let color { button.bezelColor = color }
	button.font = .systemFont(ofSize: 13, weight: .medium)
	return button
}

/// The Apple-Intelligence style gradient used for the AI widget.
public enum PAIColors {
	public static let aiGradient: [NSColor] = [
		NSColor(red: 1, green: 0.55, blue: 0.25, alpha: 1),
		NSColor.systemPink,
		NSColor.systemPurple,
		NSColor(red: 0.25, green: 0.5, blue: 1, alpha: 1)
	]
	public static let chip = NSColor(white: 0.22, alpha: 1)
}
