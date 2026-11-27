//
//  RenameMigration.swift
//  TouchPlay
//
//  TouchPlay used to be called PockAI (bundle id com.pockai.app). On the first launch under the new name:
//  • every setting is copied over (widget layout, lyrics, typing, per-app choices, AI key…),
//  • the old auto-restart agent is removed so it can't start the old app again,
//  • a still-running PockAI is asked to quit, so two copies never fight over the Touch Bar.
//

import AppKit

enum RenameMigration {
	private static let oldBundleID = "com.pockai.app"
	private static let doneKey = "touchplay.migratedFromPockAI"

	static func run() {
		retireOldCopy()
		let defaults = UserDefaults.standard
		guard !defaults.bool(forKey: doneKey) else { return }
		if let old = defaults.persistentDomain(forName: oldBundleID) {
			for (key, value) in old where defaults.object(forKey: key) == nil {
				defaults.set(value, forKey: key)
			}
			NSLog("[TouchPlay] Copied \(old.count) settings from PockAI.")
		}
		defaults.set(true, forKey: doneKey)
	}

	private static func retireOldCopy() {
		for app in NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID) {
			app.terminate()
		}
		let agent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.pockai.app.agent.plist")
		guard FileManager.default.fileExists(atPath: agent.path) else { return }
		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
		task.arguments = ["bootout", "gui/\(getuid())/com.pockai.app.agent"]
		try? task.run()
		task.waitUntilExit()
		try? FileManager.default.removeItem(at: agent)
	}
}
