import AppKit
import PockKit

/// TouchPlay's Control Center: one full Touch Bar of switches and handy actions.
///
///   ✕ | ☼ ───── ☀︎  ⌨︎ ───── ⌨︎  🔈 ───── 🔊 | Wi-Fi  Bluetooth  Dark  Night Shift  Awake  Mic | Desktop  Mission  Launchpad
///     | Screenshot  AirDrop  Eject  Hide icons  Focus | Lock  Display off  Sleep
///
/// Swipe to see everything. Switches light up blue when on and re-read the real state every 2 seconds,
/// so they stay right when you change something elsewhere. Opened from the Control Center widget (⊞),
/// the Quick Actions widget (⊞) or `local.pockai.controls.open`.
public final class ControlPanel: PKTouchBarController {

	private static let closeId = NSTouchBarItem.Identifier("com.touchplay.controls.close")
	private static let contentId = NSTouchBarItem.Identifier("com.touchplay.controls.content")
	private static weak var current: ControlPanel?

	public static func open() {
		if let current, current.isVisible { return }
		let panel = ControlPanel()
		current = panel
		if let nav = panel.mainNavigationController {
			nav.popToRootController()
			nav.push(panel)
		} else {
			panel.present()
		}
	}

	/// Registers the automation hook once (call at launch).
	public static func registerHook() {
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.controls.open"), object: nil, queue: .main) { _ in open() }
	}

	// MARK: Tiles

	private struct Toggle {
		let symbol: String, title: String
		let available: () -> Bool
		let isOn: () -> Bool
		let set: (Bool) -> Void
	}

	private struct Action {
		let symbol: String, title: String
		let color: NSColor?
		let run: () -> Void
	}

	private let toggles: [Toggle] = [
		Toggle(symbol: "wifi", title: "Wi-Fi", available: { SystemControls.wifiAvailable }, isOn: { SystemControls.wifiOn }, set: SystemControls.setWifi),
		Toggle(symbol: "dot.radiowaves.left.and.right", title: "Bluetooth", available: { SystemControls.bluetoothAvailable },
			   isOn: { SystemControls.bluetoothOn }, set: SystemControls.setBluetooth),
		Toggle(symbol: "circle.lefthalf.filled", title: "Dark", available: { true }, isOn: { SystemControls.darkMode }, set: SystemControls.setDarkMode),
		Toggle(symbol: "sun.haze.fill", title: "Night Shift", available: { SystemControls.nightShiftAvailable },
			   isOn: { SystemControls.nightShiftOn }, set: SystemControls.setNightShift),
		Toggle(symbol: "cup.and.saucer.fill", title: "Awake", available: { true }, isOn: { SystemControls.keepAwake }, set: SystemControls.setKeepAwake),
		Toggle(symbol: "mic.slash.fill", title: "Mic off", available: { true }, isOn: { SystemControls.micMuted }, set: SystemControls.setMicMuted),
		Toggle(symbol: "eye.slash", title: "Hide icons", available: { true },
			   isOn: { SystemControls.desktopIconsHidden }, set: SystemControls.setDesktopIconsHidden),
	]

	private let actions: [Action] = [
		Action(symbol: "menubar.dock.rectangle", title: "Desktop", color: nil, run: SystemControls.showDesktop),
		Action(symbol: "rectangle.3.group", title: "Mission", color: nil, run: SystemControls.missionControl),
		Action(symbol: "square.grid.3x3.fill", title: "Launchpad", color: nil, run: SystemControls.launchpad),
		Action(symbol: "camera.viewfinder", title: "Screenshot", color: nil, run: SystemControls.screenshot),
		Action(symbol: "airplayaudio", title: "AirDrop", color: nil, run: SystemControls.airDrop),
		Action(symbol: "eject.fill", title: "Eject", color: nil, run: { SystemControls.ejectAll() }),
		Action(symbol: "moon.fill", title: "Focus", color: nil, run: SystemControls.focusSettings),
		Action(symbol: "lock.fill", title: "Lock", color: NSColor(red: 0.35, green: 0.25, blue: 0.55, alpha: 1), run: SystemControls.lock),
		Action(symbol: "display", title: "Screen off", color: NSColor(red: 0.35, green: 0.25, blue: 0.55, alpha: 1), run: SystemControls.displayOff),
		Action(symbol: "powersleep", title: "Sleep", color: NSColor(red: 0.45, green: 0.22, blue: 0.3, alpha: 1), run: SystemControls.sleepMac),
	]

	/// A slider with a small "less" icon on its left and a big "more" icon on its right: tap an icon to step,
	/// drag the slider for any value.
	private struct Level {
		let less: String, more: String
		let available: () -> Bool
		let get: () -> Float
		let set: (Float) -> Void
		let step: Float
	}

	private let levels: [Level] = [
		Level(less: "sun.min.fill", more: "sun.max.fill", available: { true },
			  get: { SystemControls.brightness }, set: { SystemControls.brightness = $0 }, step: 1.0 / 16.0),
		Level(less: "light.min", more: "light.max", available: { SystemControls.keyboardBrightnessAvailable },
			  get: { SystemControls.keyboardBrightness }, set: { SystemControls.keyboardBrightness = $0 }, step: 1.0 / 16.0),
		Level(less: "speaker.fill", more: "speaker.wave.3.fill", available: { true },
			  get: { SystemControls.volume }, set: { SystemControls.volume = $0 }, step: 1.0 / 16.0),
	]

	private var toggleButtons: [Int: NSButton] = [:]
	private var sliders: [Int: NSSlider] = [:]
	private var refreshTimer: Timer?
	private lazy var content: NSView = buildContent()

	// MARK: Bar

	public override func makeTouchBar() -> NSTouchBar? {
		let bar = NSTouchBar()
		bar.delegate = self
		bar.defaultItemIdentifiers = [Self.closeId, Self.contentId]
		return bar
	}

	@objc public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
		let item = NSCustomTouchBarItem(identifier: identifier)
		switch identifier {
		case Self.closeId:
			let b = PAIButton(symbol: "xmark", target: self, action: #selector(close))
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
			item.view = b
		case Self.contentId:
			item.view = content
		default:
			return nil
		}
		return item
	}

	public override func present() {
		super.present()
		startRefreshing()
	}

	public override func dismiss() {
		refreshTimer?.invalidate()
		refreshTimer = nil
		super.dismiss()
		if Self.current === self { Self.current = nil }
	}

	public override func minimize() {
		refreshTimer?.invalidate()
		refreshTimer = nil
		super.minimize()
	}

	@objc private func close() { dismiss() }

	// MARK: Content

	private func buildContent() -> NSView {
		let width = TouchBarMetrics.fullBarContentWidth(reserving: 44)
		let stack = NSStackView()
		stack.orientation = .horizontal
		stack.alignment = .centerY
		stack.spacing = 6

		for (i, level) in levels.enumerated() where level.available() {
			stack.addArrangedSubview(levelRow(level, index: i))
		}
		stack.addArrangedSubview(divider())
		for (i, t) in toggles.enumerated() where t.available() {
			let b = tile(symbol: t.symbol, title: t.title, action: #selector(toggleTapped(_:)))
			b.tag = i
			toggleButtons[i] = b
			stack.addArrangedSubview(b)
		}
		stack.addArrangedSubview(divider())
		for (i, a) in actions.enumerated() {
			let b = tile(symbol: a.symbol, title: a.title, action: #selector(actionTapped(_:)))
			b.tag = i
			if let color = a.color { b.bezelColor = color }
			stack.addArrangedSubview(b)
		}
		refreshStates()

		// Lay the pieces out at their exact widths (auto-sizing inside a scroll view squeezed the first tiles).
		let strip = NSView()
		var x: CGFloat = 0
		for view in stack.arrangedSubviews {
			stack.removeArrangedSubview(view)
			view.removeFromSuperview()
			let w = itemWidth(view)
			view.translatesAutoresizingMaskIntoConstraints = true
			view.frame = NSRect(x: x, y: 0, width: w, height: 30)
			if view.frame.height != 30 || w < 2 { view.frame.origin.y = 5; view.frame.size.height = 20 }
			strip.addSubview(view)
			x += w + 6
		}
		strip.frame = NSRect(x: 0, y: 0, width: max(width, x), height: 30)
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
		scroll.hasHorizontalScroller = false
		scroll.hasVerticalScroller = false
		scroll.horizontalScrollElasticity = .allowed
		scroll.verticalScrollElasticity = .none
		scroll.drawsBackground = false
		scroll.allowedTouchTypes = [.direct]
		scroll.documentView = strip
		scroll.translatesAutoresizingMaskIntoConstraints = false
		scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
		scroll.heightAnchor.constraint(equalToConstant: 30).isActive = true
		return scroll
	}

	/// Width a piece of the strip needs: buttons by their content, slider rows icon + slider, dividers 1 pt.
	private func itemWidth(_ view: NSView) -> CGFloat {
		if let b = view as? NSButton { return ceil(b.intrinsicContentSize.width) + 16 }
		if view is NSStackView { return Self.levelRowWidth }
		return 1
	}

	private func tile(symbol: String, title: String, action: Selector) -> NSButton {
		let b = PAIButton(symbol: symbol, title: title, target: self, action: action)
		b.font = .systemFont(ofSize: 12, weight: .medium)
		b.bezelColor = PAIColors.chip
		b.setContentHuggingPriority(.required, for: .horizontal)
		b.setContentCompressionResistancePriority(.required, for: .horizontal)
		return b
	}

	private static let stepButtonWidth: CGFloat = 34
	private static let sliderWidth: CGFloat = 100
	private static let levelRowWidth: CGFloat = stepButtonWidth * 2 + sliderWidth + 4 * 2

	/// [small icon −] ───slider─── [big icon +]
	private func levelRow(_ level: Level, index: Int) -> NSView {
		func stepButton(_ symbol: String, size: CGFloat, action: Selector) -> NSButton {
			let b = PAIButton(symbol: symbol, target: self, action: action)
			b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
				.withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
			b.bezelColor = PAIColors.chip
			b.tag = index
			b.translatesAutoresizingMaskIntoConstraints = false
			b.widthAnchor.constraint(equalToConstant: Self.stepButtonWidth).isActive = true
			return b
		}
		let less = stepButton(level.less, size: 11, action: #selector(stepDown(_:)))
		let more = stepButton(level.more, size: 17, action: #selector(stepUp(_:)))
		let s = NSSlider(value: Double(level.get()), minValue: 0, maxValue: 1, target: self, action: #selector(sliderChanged(_:)))
		s.isContinuous = true
		s.tag = index
		s.translatesAutoresizingMaskIntoConstraints = false
		s.widthAnchor.constraint(equalToConstant: Self.sliderWidth).isActive = true
		s.controlSize = .small
		sliders[index] = s
		let row = NSStackView(views: [less, s, more])
		row.spacing = 4
		return row
	}

	private func divider() -> NSView {
		let v = NSView()
		v.wantsLayer = true
		v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
		v.translatesAutoresizingMaskIntoConstraints = false
		v.widthAnchor.constraint(equalToConstant: 1).isActive = true
		v.heightAnchor.constraint(equalToConstant: 20).isActive = true
		return v
	}

	// MARK: Actions

	@objc private func toggleTapped(_ sender: NSButton) {
		guard toggles.indices.contains(sender.tag) else { return }
		let t = toggles[sender.tag]
		let newValue = !t.isOn()
		// Show the new state right away; the real state is read back a moment later.
		paint(sender, on: newValue)
		DispatchQueue.global(qos: .userInitiated).async {
			t.set(newValue)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refreshStates() }
		}
	}

	@objc private func actionTapped(_ sender: NSButton) {
		guard actions.indices.contains(sender.tag) else { return }
		let action = actions[sender.tag]
		// Lock / screen off / sleep / Mission Control leave the bar: close the panel first.
		if ["Lock", "Screen off", "Sleep", "Mission", "Launchpad", "Desktop"].contains(action.title) { dismiss() }
		action.run()
	}

	@objc private func sliderChanged(_ sender: NSSlider) {
		guard levels.indices.contains(sender.tag) else { return }
		levels[sender.tag].set(sender.floatValue)
	}

	@objc private func stepDown(_ sender: NSButton) { step(sender.tag, by: -1) }
	@objc private func stepUp(_ sender: NSButton) { step(sender.tag, by: 1) }

	private func step(_ index: Int, by direction: Float) {
		guard levels.indices.contains(index) else { return }
		let level = levels[index]
		let value = min(1, max(0, level.get() + direction * level.step))
		level.set(value)
		sliders[index]?.floatValue = value
	}

	// MARK: State

	private func startRefreshing() {
		refreshTimer?.invalidate()
		refreshStates()
		let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStates() }
		t.tolerance = 0.5
		RunLoop.main.add(t, forMode: .common)
		refreshTimer = t
	}

	private func refreshStates() {
		for (i, button) in toggleButtons where toggles.indices.contains(i) {
			paint(button, on: toggles[i].isOn())
		}
		for (i, s) in sliders where levels.indices.contains(i) && !s.isHighlighted {
			s.floatValue = levels[i].get()
		}
	}

	private func paint(_ button: NSButton, on: Bool) {
		button.bezelColor = on ? NSColor.systemBlue : PAIColors.chip
	}
}
