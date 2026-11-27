import AppKit
import CoreAudio
import CoreWLAN
import IOKit.pwr_mgt

/// Switches and actions for the Control Center panel. Everything runs without admin rights or extra
/// permission prompts: public APIs where they exist, Apple's own private calls (resolved at run time, so a
/// missing one just disables that button) where they don't. Nothing here blocks the main thread.
public enum SystemControls {

	// MARK: Wi-Fi

	public static var wifiAvailable: Bool { CWWiFiClient.shared().interface() != nil }
	public static var wifiOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }
	public static func setWifi(_ on: Bool) {
		guard let iface = CWWiFiClient.shared().interface() else { return }
		do { try iface.setPower(on) } catch {
			// Some setups only allow it through networksetup (no admin needed for the current user).
			if let name = iface.interfaceName { run("/usr/sbin/networksetup", ["-setairportpower", name, on ? "on" : "off"]) }
		}
	}

	// MARK: Bluetooth (IOBluetooth's preference calls, as used by `blueutil`)

	private static let bluetooth = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
	public static var bluetoothAvailable: Bool { dlsym(bluetooth, "IOBluetoothPreferenceSetControllerPowerState") != nil }
	public static var bluetoothOn: Bool {
		typealias Get = @convention(c) () -> Int32
		guard let f = dlsym(bluetooth, "IOBluetoothPreferenceGetControllerPowerState") else { return false }
		return unsafeBitCast(f, to: Get.self)() != 0
	}
	public static func setBluetooth(_ on: Bool) {
		typealias Set = @convention(c) (Int32) -> Void
		guard let f = dlsym(bluetooth, "IOBluetoothPreferenceSetControllerPowerState") else { return }
		unsafeBitCast(f, to: Set.self)(on ? 1 : 0)
	}

	// MARK: Dark mode (SkyLight, the call System Settings uses)

	private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
	public static var darkMode: Bool {
		typealias Get = @convention(c) () -> Bool
		if let f = dlsym(skyLight, "SLSGetAppearanceThemeLegacy") { return unsafeBitCast(f, to: Get.self)() }
		return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
	}
	public static func setDarkMode(_ on: Bool) {
		typealias Set = @convention(c) (Bool) -> Void
		if let f = dlsym(skyLight, "SLSSetAppearanceThemeLegacy") {
			unsafeBitCast(f, to: Set.self)(on)
		} else {
			run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"])
		}
	}

	// MARK: Night Shift (CoreBrightness)

	private static let blueLight: NSObject? = {
		_ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
		return (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
	}()
	public static var nightShiftAvailable: Bool { blueLight != nil }
	public static var nightShiftOn: Bool {
		guard let client = blueLight else { return false }
		let sel = NSSelectorFromString("getBlueLightStatus:")
		guard client.responds(to: sel), let imp = client.method(for: sel) else { return false }
		typealias Get = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
		var status = [UInt8](repeating: 0, count: 64)       // { BOOL active (supported); BOOL enabled (on now); … }
		let ok = status.withUnsafeMutableBytes { unsafeBitCast(imp, to: Get.self)(client, sel, $0.baseAddress!) }
		return ok && status[1] != 0
	}
	public static func setNightShift(_ on: Bool) {
		guard let client = blueLight else { return }
		let sel = NSSelectorFromString("setEnabled:")
		guard client.responds(to: sel), let imp = client.method(for: sel) else { return }
		typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Bool
		_ = unsafeBitCast(imp, to: Set.self)(client, sel, on)
	}

	// MARK: Keep awake (like `caffeinate`: display and Mac stay on while it's on)

	private static var awakeAssertion: IOPMAssertionID = 0
	public static var keepAwake: Bool { awakeAssertion != 0 }
	public static func setKeepAwake(_ on: Bool) {
		if on, awakeAssertion == 0 {
			var id: IOPMAssertionID = 0
			if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
										   "TouchPlay Keep Awake" as CFString, &id) == kIOReturnSuccess {
				awakeAssertion = id
			}
		} else if !on, awakeAssertion != 0 {
			IOPMAssertionRelease(awakeAssertion)
			awakeAssertion = 0
		}
	}

	// MARK: Sound

	private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
		var id = AudioDeviceID(0)
		var size = UInt32(MemoryLayout<AudioDeviceID>.size)
		var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
		return id
	}

	private static let mainVolume: AudioObjectPropertySelector = 0x766d7663   // 'vmvc' virtual main volume

	public static var volume: Float {
		get {
			guard let dev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return 0 }
			var value = Float32(0)
			var size = UInt32(MemoryLayout<Float32>.size)
			var address = AudioObjectPropertyAddress(mSelector: mainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
			return AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &value) == noErr ? value : 0
		}
		set {
			guard let dev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return }
			var value = Float32(min(1, max(0, newValue)))
			var address = AudioObjectPropertyAddress(mSelector: mainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
			AudioObjectSetPropertyData(dev, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
			if value > 0 { setMute(false, input: false) }
		}
	}

	private static func mute(input: Bool) -> Bool {
		guard let dev = defaultDevice(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice) else { return false }
		var value = UInt32(0)
		var size = UInt32(MemoryLayout<UInt32>.size)
		var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
												 mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
		return AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &value) == noErr && value != 0
	}

	private static func setMute(_ on: Bool, input: Bool) {
		guard let dev = defaultDevice(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice) else { return }
		var value = UInt32(on ? 1 : 0)
		var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
												 mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
		if AudioObjectSetPropertyData(dev, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) != noErr, input {
			// Microphones without a mute switch: turn the input level down / back up instead.
			run("/usr/bin/osascript", ["-e", "set volume input volume \(on ? 0 : 75)"])
			micFallbackMuted = on
		}
	}

	private static var micFallbackMuted = false
	public static var soundMuted: Bool { mute(input: false) }
	public static func setSoundMuted(_ on: Bool) { setMute(on, input: false) }
	public static var micMuted: Bool { mute(input: true) || micFallbackMuted }
	public static func setMicMuted(_ on: Bool) { setMute(on, input: true) }

	// MARK: Brightness (built-in display)

	private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
	public static var brightness: Float {
		get {
			typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
			guard let f = dlsym(displayServices, "DisplayServicesGetBrightness") else { return 0.5 }
			var value: Float = 0.5
			_ = unsafeBitCast(f, to: Get.self)(CGMainDisplayID(), &value)
			return value
		}
		set {
			typealias Set = @convention(c) (UInt32, Float) -> Int32
			guard let f = dlsym(displayServices, "DisplayServicesSetBrightness") else { return }
			_ = unsafeBitCast(f, to: Set.self)(CGMainDisplayID(), min(1, max(0.02, newValue)))
		}
	}

	// MARK: Keyboard backlight (CoreBrightness, same as the F5 / F6 keys)

	private static let keyboardClient: NSObject? = {
		_ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
		guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
		return cls.init()
	}()
	private static let keyboardID: UInt64? = {
		guard let client = keyboardClient, client.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")),
			  let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else { return nil }
		return ids.first?.uint64Value
	}()
	public static var keyboardBrightnessAvailable: Bool {
		guard let client = keyboardClient, keyboardID != nil else { return false }
		return client.responds(to: NSSelectorFromString("brightnessForKeyboard:"))
			&& client.responds(to: NSSelectorFromString("setBrightness:forKeyboard:"))
	}
	public static var keyboardBrightness: Float {
		get {
			guard keyboardBrightnessAvailable, let client = keyboardClient, let id = keyboardID else { return 0 }
			typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
			let sel = NSSelectorFromString("brightnessForKeyboard:")
			return unsafeBitCast(client.method(for: sel), to: Get.self)(client, sel, id)
		}
		set {
			guard keyboardBrightnessAvailable, let client = keyboardClient, let id = keyboardID else { return }
			typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
			let sel = NSSelectorFromString("setBrightness:forKeyboard:")
			_ = unsafeBitCast(client.method(for: sel), to: Set.self)(client, sel, min(1, max(0, newValue)), id)
		}
	}

	// MARK: Desktop & windows (the Dock's own triggers, same as the F3 / F4 / F11 keys)

	private static func dock(_ name: String) {
		typealias Send = @convention(c) (CFString, UnsafeRawPointer?) -> Void
		guard let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return }
		unsafeBitCast(f, to: Send.self)(name as CFString, nil)
	}
	public static func showDesktop() { dock("com.apple.showdesktop.awake") }
	public static func missionControl() { dock("com.apple.expose.awake") }
	public static func launchpad() { dock("com.apple.launchpad.toggle") }

	public static var desktopIconsHidden: Bool {
		(UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool) == false
	}
	public static func setDesktopIconsHidden(_ hidden: Bool) {
		run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"]) {
			run("/usr/bin/killall", ["Finder"])
		}
	}

	// MARK: One-tap actions

	public static func screenshot() { run("/usr/bin/open", ["-a", "Screenshot"]) }
	public static func airDrop() { run("/usr/bin/open", ["/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"]) }
	public static func focusSettings() { run("/usr/bin/open", ["x-apple.systempreferences:com.apple.Focus-Settings.extension"]) }
	public static func displayOff() { run("/usr/bin/pmset", ["displaysleepnow"]) }
	public static func sleepMac() { run("/usr/bin/pmset", ["sleepnow"]) }

	public static func lock() {
		typealias Fn = @convention(c) () -> Void
		if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
		   let f = dlsym(h, "SACLockScreenImmediate") {
			unsafeBitCast(f, to: Fn.self)()
		} else {
			displayOff()
		}
	}

	/// Ejects every removable disk (USB sticks, SD cards, disk images). Returns how many were asked to eject.
	@discardableResult public static func ejectAll() -> Int {
		let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
		let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
		var count = 0
		for url in volumes {
			guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsEjectable == true || (v.volumeIsRemovable == true && v.volumeIsInternal != true) else { continue }
			count += 1
			DispatchQueue.global().async { try? NSWorkspace.shared.unmountAndEjectDevice(at: url) }
		}
		return count
	}

	// MARK: Helpers

	static func run(_ path: String, _ args: [String], then: (() -> Void)? = nil) {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: path)
		p.arguments = args
		p.standardOutput = FileHandle.nullDevice
		p.standardError = FileHandle.nullDevice
		if let then { p.terminationHandler = { _ in DispatchQueue.main.async(execute: then) } }
		try? p.run()
	}
}
