import AppKit

/// The extra one-tap buttons the Control Center widget can show (switched on/off in its settings).
/// One list, used by both the widget (what to draw, what a tap does) and its settings page (the checkboxes).
public enum ControlCenterButtons {

	public struct Button {
		public let id: String
		public let name: String
		/// Symbol when off / for an action, and when on (switches only).
		public let symbol: String
		public let onSymbol: String?
		public let defaultOn: Bool
		public let isOn: (() -> Bool)?
		public let available: () -> Bool
		public let run: () -> Void

		public var key: String { "touchplay.cc.\(id)" }
		public var isEnabled: Bool { (UserDefaults.standard.object(forKey: key) as? Bool ?? defaultOn) && available() }
		public var isSwitch: Bool { isOn != nil }

		public func currentSymbol() -> String {
			guard let isOn, let onSymbol else { return symbol }
			return isOn() ? onSymbol : symbol
		}
	}

	/// Posted (on NSWorkspace's centre) whenever a checkbox changes, so the widget redraws.
	public static let reloadNotification = Notification.Name("shouldReloadControlCenterWidget")

	/// Keyboard backlight step per tap (16 steps, like the F5 / F6 keys).
	private static let keyboardStep: Float = 1.0 / 16.0

	public static let keyboard: [Button] = [
		Button(id: "kbdDown", name: "Keyboard light down", symbol: "light.min", onSymbol: nil, defaultOn: true, isOn: nil,
			   available: { SystemControls.keyboardBrightnessAvailable },
			   run: { SystemControls.keyboardBrightness -= keyboardStep }),
		Button(id: "kbdUp", name: "Keyboard light up", symbol: "light.max", onSymbol: nil, defaultOn: true, isOn: nil,
			   available: { SystemControls.keyboardBrightnessAvailable },
			   run: { SystemControls.keyboardBrightness += keyboardStep }),
	]

	public static let quick: [Button] = [
		Button(id: "wifi", name: "Wi-Fi", symbol: "wifi.slash", onSymbol: "wifi", defaultOn: false,
			   isOn: { SystemControls.wifiOn }, available: { SystemControls.wifiAvailable },
			   run: { SystemControls.setWifi(!SystemControls.wifiOn) }),
		Button(id: "bluetooth", name: "Bluetooth", symbol: "personalhotspot", onSymbol: "dot.radiowaves.left.and.right", defaultOn: false,
			   isOn: { SystemControls.bluetoothOn }, available: { SystemControls.bluetoothAvailable },
			   run: { SystemControls.setBluetooth(!SystemControls.bluetoothOn) }),
		Button(id: "dark", name: "Dark mode", symbol: "circle.lefthalf.filled", onSymbol: "circle.righthalf.filled", defaultOn: false,
			   isOn: { SystemControls.darkMode }, available: { true },
			   run: { SystemControls.setDarkMode(!SystemControls.darkMode) }),
		Button(id: "nightShift", name: "Night Shift", symbol: "sun.max", onSymbol: "sun.haze.fill", defaultOn: false,
			   isOn: { SystemControls.nightShiftOn }, available: { SystemControls.nightShiftAvailable },
			   run: { SystemControls.setNightShift(!SystemControls.nightShiftOn) }),
		Button(id: "awake", name: "Keep awake", symbol: "cup.and.saucer", onSymbol: "cup.and.saucer.fill", defaultOn: false,
			   isOn: { SystemControls.keepAwake }, available: { true },
			   run: { SystemControls.setKeepAwake(!SystemControls.keepAwake) }),
		Button(id: "mic", name: "Microphone", symbol: "mic.fill", onSymbol: "mic.slash.fill", defaultOn: false,
			   isOn: { SystemControls.micMuted }, available: { true },
			   run: { SystemControls.setMicMuted(!SystemControls.micMuted) }),
		Button(id: "screenshot", name: "Screenshot", symbol: "camera.viewfinder", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: SystemControls.screenshot),
		Button(id: "desktop", name: "Show Desktop", symbol: "menubar.dock.rectangle", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: SystemControls.showDesktop),
		Button(id: "mission", name: "Mission Control", symbol: "rectangle.3.group", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: SystemControls.missionControl),
		Button(id: "launchpad", name: "Launchpad", symbol: "square.grid.3x3.fill", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: SystemControls.launchpad),
		Button(id: "airdrop", name: "AirDrop", symbol: "airplayaudio", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: SystemControls.airDrop),
		Button(id: "focus", name: "Focus", symbol: "moon.fill", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: SystemControls.focusSettings),
		Button(id: "eject", name: "Eject disks", symbol: "eject.fill", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: { SystemControls.ejectAll() }),
		Button(id: "screenOff", name: "Screen off", symbol: "display", onSymbol: nil, defaultOn: false, isOn: nil,
			   available: { true }, run: SystemControls.displayOff),
	]

	public static var all: [Button] { keyboard + quick }

	/// Quick Actions used to be its own widget: switch the same buttons on here, once, and take that widget
	/// off the bar (Control Center now holds them). Returns true when the bar layout changed.
	@discardableResult
	public static func absorbQuickActions(layoutKey: String) -> Bool {
		let defaults = UserDefaults.standard
		let doneKey = "touchplay.cc.absorbedQuickActions"
		guard !defaults.bool(forKey: doneKey) else { return false }
		defaults.set(true, forKey: doneKey)
		let quickId = "com.pockai.widget.QuickActions"
		guard var config = defaults.dictionary(forKey: layoutKey), var items = config["CurrentItems"] as? [String],
			  items.contains(quickId) else { return false }
		let enabled = Set(defaults.stringArray(forKey: "pockai.quick.enabled")
			?? ["Screenshot", "Lock", "Display sleep", "Dark mode", "Focus", "Wi-Fi", "Show Desktop", "More"])
		let map: [String: String] = ["Screenshot": "touchplay.cc.screenshot", "Display sleep": "touchplay.cc.screenOff",
									 "Dark mode": "touchplay.cc.dark", "Focus": "touchplay.cc.focus", "Wi-Fi": "touchplay.cc.wifi",
									 "Show Desktop": "touchplay.cc.desktop", "More": "touchplay.cc.more", "Lock": "shouldShowLockItem"]
		for (name, key) in map where enabled.contains(name) { defaults.set(true, forKey: key) }
		items.removeAll { $0 == quickId }
		config["CurrentItems"] = items
		defaults.set(config, forKey: layoutKey)
		return true
	}
}
