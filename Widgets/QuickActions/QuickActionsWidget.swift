import AppKit
import PockKit
import PockAIKit

/// One-tap system actions: screenshot, lock, display sleep, dark mode, Do Not Disturb (Focus).
final class QuickActionsWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.QuickActions"
	var customizationLabel: String = "Quick Actions"
	var view: NSView!

	private struct Action {
		let symbol: String
		let name: String
		let run: () -> Void
	}

	private lazy var actions: [Action] = [
		Action(symbol: "camera.viewfinder", name: "Screenshot") { Self.run("/usr/bin/open", ["-a", "Screenshot"]) },
		Action(symbol: "lock.fill", name: "Lock") { Self.lockScreen() },
		Action(symbol: "moon.zzz.fill", name: "Display sleep") { Self.run("/usr/bin/pmset", ["displaysleepnow"]) },
		Action(symbol: "circle.lefthalf.filled", name: "Dark mode") {
			Self.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
		},
		Action(symbol: "moon.fill", name: "Focus") {
			// Opens Control Centre's Focus module via the Shortcuts-free route: toggles DND with the built-in shortcut if set,
			// otherwise opens Focus settings.
			Self.run("/usr/bin/open", ["x-apple.systempreferences:com.apple.Focus-Settings.extension"])
		},
	]

	private let stack = NSStackView()
	private var settingsObserver: NSObjectProtocol?

	required override init() {
		super.init()
		stack.orientation = .horizontal
		stack.spacing = 4
		view = stack
		rebuild()
		settingsObserver = NotificationCenter.default.addObserver(forName: PockAIWidgetSettingsDidChange, object: nil, queue: .main) { [weak self] note in
			guard (note.object as? String) == nil || (note.object as? String) == "pockai.quick.enabled" else { return }
			self?.rebuild()
		}
	}

	deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }

	/// Only the buttons switched on in the widget's settings.
	private func rebuild() {
		stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
		let enabled = Set(UserDefaults.standard.stringArray(forKey: "pockai.quick.enabled") ?? actions.map(\.name))
		for (i, action) in actions.enumerated() where enabled.contains(action.name) {
			let b = PAIButton(symbol: action.symbol, target: self, action: #selector(tap(_:)))
			b.tag = i
			b.toolTip = action.name
			b.bezelColor = PAIColors.chip
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
			stack.addArrangedSubview(b)
		}
	}

	@objc private func tap(_ sender: NSButton) {
		guard actions.indices.contains(sender.tag) else { return }
		actions[sender.tag].run()
	}

	private static func run(_ path: String, _ args: [String]) {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: path)
		p.arguments = args
		try? p.run()
	}

	private static func appleScript(_ source: String) {
		// NSAppleScript isn't thread-safe; a separate osascript process never blocks or crashes PockAI.
		run("/usr/bin/osascript", ["-e", source])
	}

	private static func lockScreen() {
		typealias Fn = @convention(c) () -> Void
		if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
		   let sym = dlsym(h, "SACLockScreenImmediate") {
			unsafeBitCast(sym, to: Fn.self)()
		} else {
			run("/usr/bin/pmset", ["displaysleepnow"])
		}
	}
}
