//
//  PockTouchBarController.swift
//  Pock
//
//  Created by Pierluigi Galdi on 10/03/21.
//

import AppKit
import Foundation
import PockKit
import PockAIKit

/// Customization identifier
extension NSTouchBar.CustomizationIdentifier {
	static let pockTouchBarController = "PockTouchBarController"
}

/// Pock (main Touch Bar controller)
internal class PockTouchBarController: PKTouchBarMouseController {

	/// Data
	private(set) var widgets: [NSTouchBarItem.Identifier: PKWidgetInfo] = [:]
	private(set) var cachedItems: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
	
	private var currentItems: [NSTouchBarItem.Identifier] {
		return modelBar.itemIdentifiers
	}
	private var emptyTouchBarController: EmptyTouchBarController?
	
	internal var allowedCustomizationIdentifiers: [NSTouchBarItem.Identifier] {
		return Array(widgets.keys) + [.flexibleSpace]
	}
	
	// MARK: Mouse Support
	private var touchBarView: NSView? {
		guard let views = NSFunctionRow._topLevelViews() as? [NSView], let view = views.last else {
            Roger.debug("Touch Bar is not available.")
            return nil
		}
		return view
	}
	public override var parentView: NSView? {
		get {
			return touchBarView
		} set {
			super.parentView = newValue
		}
	}
	
	// MARK: Live size changes of PockAI widgets
	private var refreshScheduled = false

	/// Item views that grow / shrink after the bar is on screen don't reach the Touch Bar process by
	/// themselves; re-present the same bar (cheap, no widgets are recreated) to apply the new layout.
	@objc private func widgetSizeDidChange(_ note: Notification) {
		guard isVisible, !refreshScheduled else { return }
		refreshScheduled = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
			guard let self, let bar = self.touchBar else { return }
			self.refreshScheduled = false
			guard self.isVisible else { return }
			if self.scrollMode { self.layoutScrollContent() }
			// Never cover the full Purr player (that's what made "tap Lyrics to reopen" do nothing).
			guard !PurrPlayer.shared.isPresented else { return }
			let placement: Int64 = (Preferences[.layoutStyle] as LayoutStyle) == .fullWidth ? 1 : 0
			NSTouchBar.presentSystemModalTouchBar(bar, placement: placement, systemTrayItemIdentifier: NSTouchBarItem.Identifier(AppTouchBarSwitcher.trayIdentifier))
		}
	}

	// MARK: Overrides
	override func didLoad() {
		super.didLoad()
		NotificationCenter.default.addObserver(self, selector: #selector(widgetSizeDidChange(_:)), name: NSNotification.Name("pockai.widget.sizeDidChange"), object: nil)
		// Debug: log the strip's layout (`local.pockai.layout`).
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.layout"), object: nil, queue: .main) { [weak self] _ in
			guard let self else { return }
			let np = NowPlayingCenter.shared.state
			NSLog("[TouchPlay layout] ax=\(AXIsProcessTrusted()) lyrics status=\(LyricsStore.shared.status) title=\(np.title) artist=\(np.artist) album=\(np.album) dur=\(np.duration) app=\(np.app ?? "-") playing=\(np.playing)")
			for v in self.scrollStack.arrangedSubviews {
				let kids = v.subviews.map { "\(type(of: $0))@\(Int($0.frame.minX))w\(Int($0.frame.width))" }.joined(separator: ", ")
				NSLog("[TouchPlay layout] \(type(of: v)) x=\(Int(v.frame.minX)) w=\(Int(v.frame.width)) fit=\(Int(v.fittingSize.width)) kids=[\(kids)]")
			}
		}
		Roger.debug("[PockTouchBarController] Loaded.")
	}
	
	deinit {
		layoutTimer?.invalidate()
		NotificationCenter.default.removeObserver(self)
		Roger.info("Deinit")
		flushWidgetItems()
		emptyTouchBarController = nil
		touchBar = nil
	}

	override func present() {
        guard AppController.shared.isLocked == false, isVisible == false else {
			return
		}
		for widget in WidgetsLoader.loadedWidgets {
			widgets[NSTouchBarItem.Identifier(widget.bundleIdentifier)] = widget
		}
		let placement: Int64
		let presentationMode: PresentationMode
		switch Preferences[.layoutStyle] as LayoutStyle {
		case .withControlStrip:
			placement = 0
			presentationMode = .appWithControlStrip
		case .fullWidth:
			placement = 1
			presentationMode = .app
		}
		isVisible = true
		if scrollMode {
			// Layout may have changed (customisation, widgets added): re-read it and rebuild the strip.
			modelBar = makeModelBar()
			touchBar = makeTouchBar()
		}
		if #available (macOS 10.14, *) {
			NSTouchBar.presentSystemModalTouchBar(touchBar, placement: placement, systemTrayItemIdentifier: NSTouchBarItem.Identifier(AppTouchBarSwitcher.trayIdentifier))
		} else {
			NSTouchBar.presentSystemModalFunctionBar(touchBar, placement: placement, systemTrayItemIdentifier: nil)
		}
		// With per-app Touch Bars on, keep the system in "app + Control Strip" mode all the time: PockAI still
		// covers the whole bar, and the PockAI button is ready in the Control Strip the moment an app's controls
		// show. Changing the mode restarts the Control Strip (slow, and taps get lost meanwhile), so set it once.
		TouchBarHelper.setPresentationMode(to: AppTouchBarSwitcher.isActive ? .appWithControlStrip : presentationMode)
		if scrollMode {
			notifyScrollWidgets(appeared: true)
			startLayoutTimer()
			// Correct the strip width once the bar has really been laid out.
			async(after: 0.3) { [weak self] in self?.layoutScrollContent() }
		}
		checkForBlankTouchBar()
	}
	
	override func minimize() {
		if scrollMode { notifyScrollWidgets(appeared: false) }
		emptyTouchBarController?.dismiss()
		super.minimize()
	}
	
	override func dismiss() {
		emptyTouchBarController?.dismiss()
		guard isVisible else {
			return
		}
		TouchBarHelper.setPresentationMode(to: Preferences[.userDefinedPresentationMode] as PresentationMode)
		if scrollMode { notifyScrollWidgets(appeared: false) }
		super.dismiss()
	}
	
	private func flushWidgetItems() {
		cachedItems.removeAll()
		widgets.removeAll()
	}

	// MARK: Scrollable bar
	//
	// Pock gives every widget its own Touch Bar item; when they don't all fit, macOS silently hides
	// whole widgets. In scroll mode the widgets (in the order you arranged them) live in one
	// horizontally scrollable strip instead, so a full bar can be swiped like the Dock.

	static let scrollItemIdentifier = NSTouchBarItem.Identifier("com.pockai.scrollContainer")

	/// Settings: "Make the bar scrollable when widgets don't fit" (default on).
	var scrollMode: Bool {
		UserDefaults.standard.object(forKey: "pockai.scrollBar") as? Bool ?? true
	}

	/// The customisable bar (holds your layout); not presented in scroll mode.
	private(set) lazy var modelBar: NSTouchBar = makeModelBar()

	private lazy var scrollView: NSScrollView = {
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 30))
		scroll.hasHorizontalScroller = false
		scroll.hasVerticalScroller = false
		scroll.horizontalScrollElasticity = .allowed
		scroll.verticalScrollElasticity = .none
		scroll.drawsBackground = false
		scroll.translatesAutoresizingMaskIntoConstraints = false
		scroll.allowedTouchTypes = [.direct]
		return scroll
	}()
	private let scrollStack: NSStackView = {
		let stack = NSStackView()
		stack.orientation = .horizontal
		stack.alignment = .centerY
		stack.spacing = 8
		stack.identifier = NSUserInterfaceItemIdentifier("pockai.scrollStack")
		stack.setHuggingPriority(.required, for: .horizontal)
		return stack
	}()
	/// [front app button][scrollable strip]: the button stays put while the widgets scroll.
	private lazy var scrollContainer: NSStackView = {
		let stack = NSStackView()
		stack.orientation = .horizontal
		stack.alignment = .centerY
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		return stack
	}()
	private var scrollWidthConstraint: NSLayoutConstraint?
	private var suggestionsWidthConstraint: NSLayoutConstraint?
	private var scrollWidgetItems: [PKWidgetTouchBarItem] = []

	/// Width the strip may take on screen.
	private var scrollViewportWidth: CGFloat {
		let button = AppTouchBarSwitcher.showsAppButton ? AppTouchBarSwitcher.buttonWidth + scrollContainer.spacing : 0
		if let bar = scrollContainer.superview, bar.bounds.width > 200 {
			return bar.bounds.width - button
		}
		switch Preferences[.layoutStyle] as LayoutStyle {
		case .fullWidth:
			return TouchBarMetrics.panelWidth - 16 - button
		case .withControlStrip:
			// Measured: 765 pt app region on a 13"/15" bar with the collapsed Control Strip.
			return TouchBarMetrics.panelWidth - (TouchBarMetrics.isSixteenInch ? 244 : 320) - button
		}
	}

	private func widgetItem(for identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
		return touchBar(modelBar, makeItemForIdentifier: identifier)
	}

	/// Rebuild the strip from your current layout.
	private func buildScrollContent() {
		TPSafely("build scroll strip") { buildScrollContentUnsafe() }
	}

	private func buildScrollContentUnsafe() {
		for view in scrollStack.arrangedSubviews {
			scrollStack.removeArrangedSubview(view)
			view.removeFromSuperview()
		}
		scrollWidgetItems.removeAll()
		for identifier in modelBar.itemIdentifiers {
			switch identifier {
			case .flexibleSpace:
				let spacer = NSView()
				spacer.translatesAutoresizingMaskIntoConstraints = false
				spacer.setContentHuggingPriority(.init(1), for: .horizontal)
				spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
				scrollStack.addArrangedSubview(spacer)
			case .fixedSpaceSmall, .fixedSpaceLarge:
				let spacer = NSView()
				spacer.translatesAutoresizingMaskIntoConstraints = false
				spacer.widthAnchor.constraint(equalToConstant: identifier == .fixedSpaceSmall ? 8 : 24).isActive = true
				scrollStack.addArrangedSubview(spacer)
			default:
				guard let item = widgetItem(for: identifier) as? NSCustomTouchBarItem else { continue }
				let view: NSView = item.view
				view.removeFromSuperview()
				scrollStack.addArrangedSubview(view)
				if let widgetItem = item as? PKWidgetTouchBarItem { scrollWidgetItems.append(widgetItem) }
			}
		}
		layoutScrollContent()
	}

	/// Widgets built on NSScrubber (Dock, Dock folders…) have no natural width; Pock relied on the bar
	/// giving them the leftover space. In the strip, give them the width of their content (capped).
	private func sizeScrubberWidgets(viewport: CGFloat) {
		for view in scrollStack.arrangedSubviews {
			let scrubbers = scrubbers(in: view)
			guard !scrubbers.isEmpty else { continue }
			var width: CGFloat = 0
			for s in scrubbers where !s.isHidden {
				// Measure from the item count: NSScrubber only reports the items it has laid out so far, so
				// sizing from that made the Dock creep wider every couple of seconds (the bar "moving by itself").
				let content: CGFloat
				if let flow = s.scrubberLayout as? NSScrubberFlowLayout, flow.itemSize.width > 0 {
					let n = CGFloat(s.numberOfItems)
					content = n * flow.itemSize.width + max(0, n - 1) * flow.itemSpacing
				} else {
					content = s.scrubberLayout.scrubberContentSize.width
				}
				// Only a width the widget set on purpose (e.g. the Dock's pinned items). Constraints AppKit makes from
				// the current frame must be ignored, or every pass adds the spacing again and the Dock creeps wider.
				let explicit = s.constraints.first {
					$0.firstAttribute == .width && $0.relation == .equal && ($0.identifier?.hasSuffix(".width") ?? false)
				}?.constant
				width += explicit ?? content
			}
			width += CGFloat(max(0, view.subviews.count - 1)) * 8 + 4
			width = min(max(width, 44), viewport * 0.7)
			if let c = view.constraints.first(where: { $0.identifier == "pockai.scrubberWidth" }) {
				if abs(c.constant - width) > 1 { c.constant = width }
			} else {
				let c = view.widthAnchor.constraint(equalToConstant: width)
				c.identifier = "pockai.scrubberWidth"
				c.priority = .defaultHigh
				c.isActive = true
			}
		}
	}

	private func scrubbers(in view: NSView) -> [NSScrubber] {
		if let s = view as? NSScrubber { return [s] }
		return view.subviews.flatMap { scrubbers(in: $0) }
	}

	private var layoutTimer: Timer?

	/// Content of widgets changes on its own (apps open/close, songs change): keep the strip in shape.
	private func startLayoutTimer() {
		layoutTimer?.invalidate()
		let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
			guard let self, self.isVisible else { return }
			self.layoutScrollContent()
		}
		t.tolerance = 0.5
		RunLoop.main.add(t, forMode: .common)
		layoutTimer = t
	}

	/// Size the strip: at least the viewport (so flexible spaces spread out), wider when content needs it.
	func layoutScrollContent() {
		TPSafely("scroll layout") { layoutScrollContentUnsafe() }
	}

	private func layoutScrollContentUnsafe() {
		let viewport = scrollViewportWidth
		sizeScrubberWidgets(viewport: viewport)
		scrollStack.layoutSubtreeIfNeeded()
		let fitting = scrollStack.fittingSize.width
		let width = max(viewport, fitting)
		scrollStack.frame = NSRect(x: 0, y: 0, width: width, height: 30)
		if scrollView.documentView !== scrollStack { scrollView.documentView = scrollStack }
		scrollWidthConstraint?.constant = viewport
		suggestionsWidthConstraint?.constant = viewport
	}

	private func notifyScrollWidgets(appeared: Bool) {
		for item in scrollWidgetItems {
			if appeared {
				item.widget?.viewWillAppear?()
				item.widget?.viewDidAppear?()
			} else {
				item.widget?.viewWillDisappear?()
				item.widget?.viewDidDisappear?()
			}
		}
	}

	/// New built-in widgets are added to the end of your layout once; if you remove one it stays removed.
	private func introduceNewWidgets() {
		let defaults = UserDefaults.standard
		let knownKey = "pockai.introducedWidgets"
		// Quick Actions moved into Control Center: take it off the bar once (its buttons are switched on there).
		ControlCenterButtons.absorbQuickActions(layoutKey: "NSTouchBarConfig: \(NSTouchBar.CustomizationIdentifier.pockTouchBarController)")
		// Widgets that existed before (you've already decided where they go).
		let baseline: Set<String> = ["com.pigigaldi.pock.Esc", "com.pigigaldi.pock.Dock", "com.pigigaldi.pock.Status",
									 "com.pigigaldi.pock.ControlCenter", "com.pigigaldi.pock.NowPlaying", "com.pigigaldi.pock.Weather",
									 "com.pockai.widget.Lyrics", "com.pockai.widget.WritingTools", "com.pockai.widget.Subtitles",
									 "com.pockai.widget.SystemMonitor"]
		var known = Set(defaults.stringArray(forKey: knownKey) ?? []).union(baseline)
		let available = widgets.keys.map(\.rawValue)
		let fresh = available.filter { !known.contains($0) }.sorted()
		guard !fresh.isEmpty else { return }
		let configKey = "NSTouchBarConfig: \(NSTouchBar.CustomizationIdentifier.pockTouchBarController)"
		if var config = defaults.dictionary(forKey: configKey), var current = config["CurrentItems"] as? [String] {
			for id in fresh where !current.contains(id) { current.append(id) }
			config["CurrentItems"] = current
			defaults.set(config, forKey: configKey)
		}
		known.formUnion(fresh)
		defaults.set(Array(known), forKey: knownKey)
	}

	private func makeModelBar() -> NSTouchBar {
		introduceNewWidgets()
		let touchBar = NSTouchBar()
		touchBar.delegate = self
		touchBar.customizationIdentifier = .pockTouchBarController
		touchBar.customizationAllowedItemIdentifiers = allowedCustomizationIdentifiers
		// First launch (nothing customised yet): start with a useful layout instead of an empty bar.
		let preferred: [String] = [
			"com.pigigaldi.pock.Esc", "com.pigigaldi.pock.Dock", NSTouchBarItem.Identifier.flexibleSpace.rawValue,
			"com.pockai.widget.WritingTools", "com.pockai.widget.Subtitles", "com.pockai.widget.Lyrics",
			"com.pigigaldi.pock.Status", "com.pigigaldi.pock.ControlCenter"
		]
		touchBar.defaultItemIdentifiers = preferred.map { NSTouchBarItem.Identifier($0) }.filter {
			$0 == .flexibleSpace || widgets[$0] != nil
		}
		for key in widgets.keys {
			Roger.info("[\(key.rawValue)] - Allowed for customization")
		}
		return touchBar
	}

	/// Setup Touch Bar (the one presented)
	override func makeTouchBar() -> NSTouchBar? {
		guard scrollMode else { return modelBar }
		let bar = NSTouchBar()
		bar.delegate = self
		bar.defaultItemIdentifiers = [Self.scrollItemIdentifier]
		return bar
	}

	/// Make Touch Bar item for given identifier
	func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
		if identifier == Self.scrollItemIdentifier {
			let item = NSCustomTouchBarItem(identifier: identifier)
			for view in scrollContainer.arrangedSubviews {
				scrollContainer.removeArrangedSubview(view)
				view.removeFromSuperview()
			}
			if AppTouchBarSwitcher.showsAppButton {
				scrollContainer.addArrangedSubview(AppTouchBarSwitcher.shared.appButton)
			}
			scrollContainer.addArrangedSubview(scrollView)
			scrollContainer.addArrangedSubview(TypingSuggestions.shared.view)
			item.view = scrollContainer
			if scrollWidthConstraint == nil {
				scrollWidthConstraint = scrollView.widthAnchor.constraint(equalToConstant: scrollViewportWidth)
				scrollWidthConstraint?.isActive = true
				scrollView.heightAnchor.constraint(equalToConstant: 30).isActive = true
				suggestionsWidthConstraint = TypingSuggestions.shared.view.widthAnchor.constraint(equalToConstant: scrollViewportWidth)
				suggestionsWidthConstraint?.isActive = true
			}
			// While you type, suggestions take the widgets' place (same width, so nothing else moves).
			scrollView.isHidden = TypingSuggestions.shared.isShowing
			TypingSuggestions.shared.onShowingChange = { [weak self] showing in
				guard let self else { return }
				self.suggestionsWidthConstraint?.constant = self.scrollViewportWidth
				self.scrollView.isHidden = showing
			}
			buildScrollContent()
			return item
		}
		if let item = cachedItems[identifier] {
			Roger.info("[\(identifier.rawValue)][item] - cached")
			return item
		}
		guard let widget = widgets[identifier] else {
			Roger.error("Can't find `NSTouchBarItem` for given identifier: `\(identifier)`")
			return nil
		}
		Roger.info("[\(identifier.rawValue)][item] - initializes")
		let item = PKWidgetTouchBarItem(widget: widget)
		if item == nil {
			NSLog("[TouchPlay] Widget `\(identifier.rawValue)` could not be created (principal class: \(String(describing: widget.principalClass)))")
		} else if let view = item?.view {
			NSLog("[TouchPlay] Widget `\(identifier.rawValue)` ready, width \(view.fittingSize.width)")
		}
		// Widgets that grow and shrink with content give way first when the bar is full.
		if ["com.pockai.widget.Subtitles", "com.pockai.widget.Lyrics", "com.pockai.widget.SystemMonitor"].contains(identifier.rawValue) {
			item?.visibilityPriority = .low
		} else if identifier.rawValue == "com.pockai.widget.WritingTools" {
			item?.visibilityPriority = .high
		}
		cachedItems[identifier] = item
		return item
	}
	
	// MARK: Blank Touch Bar
	private func checkForBlankTouchBar() {
		emptyTouchBarController?.dismiss()
		emptyTouchBarController = nil
		guard Preferences[.allowBlankTouchBar] == false else {
			return
		}
		async(after: 0.225) { [weak self] in
			guard let self = self else {
				return
			}
			if self.widgets.isEmpty {
				self.emptyTouchBarController = AppController.shared.showEmptyTouchBarController(with: .installDefault)
			} else {
				if self.currentItems.isEmpty {
					self.emptyTouchBarController = AppController.shared.showEmptyTouchBarController(with: .empty)
				}
			}
		}
	}
	
	// MARK: Mouse delegates
	
	private var mouseDelegates: [PKScreenEdgeMouseDelegate] {
		return cachedItems.values.compactMap({ ($0 as? PKWidgetTouchBarItem)?.widget as? PKScreenEdgeMouseDelegate })
	}
	
	// MARK: Mouse Overrides
	override func reloadScreenEdgeController() {
		if Preferences[.mouseSupportEnabled], let parentView = parentView {
			let color: NSColor = Preferences[.showTrackingArea] ? .systemBlue : .clear
			self.edgeController = PKScreenEdgeController(mouseDelegate: self, parentView: parentView, barColor: color)
		} else {
			self.edgeController?.tearDown(invalidate: true)
			self.edgeController = nil
		}
	}
	
	override func screenEdgeController(_ controller: PKScreenEdgeController, mouseEnteredAtLocation location: NSPoint, in view: NSView) {
		super.screenEdgeController(controller, mouseEnteredAtLocation: location, in: view)
		mouseDelegates.forEach({
			$0.screenEdgeController(controller, mouseEnteredAtLocation: location, in: view)
		})
	}
	
	override func screenEdgeController(_ controller: PKScreenEdgeController, mouseMovedAtLocation location: NSPoint, in view: NSView) {
		super.screenEdgeController(controller, mouseMovedAtLocation: location, in: view)
		mouseDelegates.forEach({
			$0.screenEdgeController(controller, mouseMovedAtLocation: location, in: view)
		})
	}
    
    private func screenEdgeController(_ controller: PKScreenEdgeController, mouseScrollWithDelta delta: CGFloat, atLocation location: NSPoint, in view: NSView, event: NSEvent) {
        mouseDelegates.forEach({
            if $0.screenEdgeController?(controller, mouseScrollWithDelta: delta, atLocation: location, in: view, event: event) == nil {
                $0.screenEdgeController?(controller, mouseScrollWithDelta: delta, atLocation: location, in: view)
            }
        })
    }
	
	override func screenEdgeController(_ controller: PKScreenEdgeController, mouseClickAtLocation location: NSPoint, in view: NSView) {
		super.screenEdgeController(controller, mouseClickAtLocation: location, in: view)
		mouseDelegates.forEach({
			$0.screenEdgeController(controller, mouseClickAtLocation: location, in: view)
		})
	}
	
	override func screenEdgeController(_ controller: PKScreenEdgeController, mouseExitedAtLocation location: NSPoint, in view: NSView) {
		super.screenEdgeController(controller, mouseExitedAtLocation: location, in: view)
		mouseDelegates.forEach({
			$0.screenEdgeController(controller, mouseExitedAtLocation: location, in: view)
		})
	}
	
	// MARK: Dragging Overrides
	override func screenEdgeController(_ controller: PKScreenEdgeController, draggingEntered info: NSDraggingInfo, filepath: String, in view: NSView) -> NSDragOperation {
		var returnable: NSDragOperation?
		for delegate in mouseDelegates {
			guard let operation = delegate.screenEdgeController?(controller, draggingEntered: info, filepath: filepath, in: view) else {
				continue
			}
			returnable = operation
			self.showDraggingInfo(info, filepath: filepath)
			break
		}
		return returnable ?? super.screenEdgeController(controller, draggingEntered: info, filepath: filepath, in: view)
	}
	
	override func screenEdgeController(_ controller: PKScreenEdgeController, draggingUpdated info: NSDraggingInfo, filepath: String, in view: NSView) -> NSDragOperation {
		var returnable: NSDragOperation?
		for delegate in mouseDelegates {
			guard let operation = delegate.screenEdgeController?(controller, draggingUpdated: info, filepath: filepath, in: view) else {
				continue
			}
			returnable = operation
			self.updateCursorLocation(info.draggingLocation)
			self.updateDraggingInfoLocation(info.draggingLocation)
			break
		}
		return returnable ?? super.screenEdgeController(controller, draggingUpdated: info, filepath: filepath, in: view)
	}
	
	override func screenEdgeController(_ controller: PKScreenEdgeController, performDragOperation info: NSDraggingInfo, filepath: String, in view: NSView) -> Bool {
		var returnable: Bool?
		for delegate in mouseDelegates {
			guard let operation = delegate.screenEdgeController?(controller, performDragOperation: info, filepath: filepath, in: view) else {
				continue
			}
			returnable = operation
			break
		}
		return returnable ?? super.screenEdgeController(controller, performDragOperation: info, filepath: filepath, in: view)
	}
	
	override func screenEdgeController(_ controller: PKScreenEdgeController, draggingEnded info: NSDraggingInfo, in view: NSView) {
		super.screenEdgeController(controller, draggingEnded: info, in: view)
		mouseDelegates.forEach({
			$0.screenEdgeController?(controller, draggingEnded: info, in: view)
		})
	}

}
