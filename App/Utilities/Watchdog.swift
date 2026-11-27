import AppKit

/// Keeps PockAI running: a per-user launchd agent starts it at login and relaunches it within a few
/// seconds if it ever crashes or hangs-and-gets-killed. Choosing Quit (a clean exit) is respected.
///
/// Only active for the installed app (~/Applications or /Applications), never for builds run from Xcode.
enum Watchdog {

	static let label = "com.touchplay.app.agent"

	static var plistURL: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
	}

	/// Settings → "Restart automatically if TouchPlay crashes" (and start at login).
	static var isEnabled: Bool {
		get { UserDefaults.standard.object(forKey: "pockai.watchdog") as? Bool ?? true }
		set {
			UserDefaults.standard.set(newValue, forKey: "pockai.watchdog")
			if newValue { _ = install(relaunchUnderLaunchd: false) } else { uninstall() }
		}
	}

	static var launchedByLaunchd: Bool {
		ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
	}

	private static var isInstalledCopy: Bool {
		let path = Bundle.main.bundlePath
		let home = FileManager.default.homeDirectoryForCurrentUser.path
		return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
	}

	/// Call first thing at launch. Returns true when this process should quit right away
	/// (another PockAI is already running, or launchd is about to start the supervised copy).
	static func startup() -> Bool {
		let me = ProcessInfo.processInfo.processIdentifier
		let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
			.filter { $0.processIdentifier != me && !$0.isTerminated }
		if !others.isEmpty {
			NSLog("[TouchPlay] Already running (pid \(others.map(\.processIdentifier))), quitting this copy.")
			return true
		}
		guard isInstalledCopy, isEnabled else {
			if !isEnabled { uninstall() }
			return false
		}
		return install(relaunchUnderLaunchd: !launchedByLaunchd)
	}

	/// Writes the agent; when `relaunchUnderLaunchd`, hands over to a launchd-started copy and returns true.
	@discardableResult
	private static func install(relaunchUnderLaunchd: Bool) -> Bool {
		guard let executable = Bundle.main.executablePath else { return false }
		let plist: [String: Any] = [
			"Label": label,
			"ProgramArguments": [executable],
			"RunAtLoad": true,
			// Relaunch only after a crash / kill, not after Quit.
			"KeepAlive": ["SuccessfulExit": false],
			"ThrottleInterval": 5,
			"ProcessType": "Interactive",
			"LimitLoadToSessionType": "Aqua",
		]
		let fm = FileManager.default
		try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		let existing = NSDictionary(contentsOf: plistURL)
		if existing == nil || !(existing!.isEqual(to: plist)) {
			(plist as NSDictionary).write(to: plistURL, atomically: true)
		}
		guard relaunchUnderLaunchd else { return false }
		// Let this copy exit first, then (re)load the agent so launchd owns the running PockAI.
		let uid = getuid()
		let script = """
		sleep 1
		/bin/launchctl bootout gui/\(uid)/\(label) 2>/dev/null
		/bin/launchctl bootstrap gui/\(uid) '\(plistURL.path)' || /bin/launchctl kickstart gui/\(uid)/\(label)
		"""
		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/bin/sh")
		task.arguments = ["-c", script]
		do {
			try task.run()
			NSLog("[TouchPlay] Handing over to the launchd watchdog.")
			return true
		} catch {
			NSLog("[TouchPlay] Watchdog unavailable: \(error)")
			return false
		}
	}

	static func uninstall() {
		guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
		try? FileManager.default.removeItem(at: plistURL)
		// Don't boot ourselves out while running under it; the removed plist takes effect next login.
		if !launchedByLaunchd {
			let task = Process()
			task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
			task.arguments = ["bootout", "gui/\(getuid())/\(label)"]
			try? task.run()
		}
	}
}
