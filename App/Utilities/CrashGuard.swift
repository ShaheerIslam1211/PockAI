import AppKit

/// Keeps PockAI alive and debuggable:
/// - ignores SIGPIPE (writing to a helper process that just quit must not kill the app),
/// - logs uncaught Objective-C exceptions to ~/Library/Logs/PockAI/last-crash.log,
/// - remembers a crash so the next launch can start without the widget that caused it.
enum CrashGuard {

	static var logURL: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TouchPlay/last-crash.log")
	}

	static func install() {
		signal(SIGPIPE, SIG_IGN)
		NSSetUncaughtExceptionHandler { exception in
			let text = """
			\(Date())
			\(exception.name.rawValue): \(exception.reason ?? "")
			\(exception.callStackSymbols.joined(separator: "\n"))
			"""
			try? FileManager.default.createDirectory(at: CrashGuard.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
			try? text.write(to: CrashGuard.logURL, atomically: true, encoding: .utf8)
		}
		// Exceptions thrown inside AppKit event handling are otherwise swallowed into an inconsistent state.
		UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
	}
}
