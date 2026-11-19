import AppKit
import ApplicationServices

/// Notices when text is selected in any app, so the ✨ Writing Tools button can appear on the Touch Bar.
///
/// Event-driven (mouse-up, shift/⌘A key-ups, app switches) instead of polling, so it costs nothing while idle.
/// Uses the Accessibility API; when an app doesn't expose its selection (some web views), a mouse drag or
/// double-click is treated as "probably selected" and the text is fetched with ⌘C only when you tap ✨.
public final class SelectionMonitor {

	public static let shared = SelectionMonitor()

	/// Something looks selected right now.
	public private(set) var hasSelection = false
	/// The selected text when Accessibility exposes it (never logged or stored).
	public private(set) var selectedText: String?
	/// The app the selection belongs to.
	public private(set) var sourceApp: NSRunningApplication?

	private var listeners: [UUID: (Bool) -> Void] = [:]
	private var monitors: [Any] = []
	private var workspaceObserver: NSObjectProtocol?
	private var mouseDownPoint: NSPoint?
	private var pendingCheck: DispatchWorkItem?
	private var enabledPIDs = Set<pid_t>()

	private init() {}

	// MARK: Listeners

	@discardableResult
	public func observe(_ handler: @escaping (Bool) -> Void) -> UUID {
		let id = UUID()
		listeners[id] = handler
		if listeners.count == 1 { start() }
		handler(hasSelection)
		return id
	}

	public func removeObserver(_ id: UUID?) {
		guard let id else { return }
		listeners[id] = nil
		if listeners.isEmpty { stop() }
	}

	private func set(_ value: Bool, text: String?) {
		selectedText = text
		guard value != hasSelection else { return }
		hasSelection = value
		listeners.values.forEach { $0(value) }
	}

	/// Forget the current selection (e.g. after the text was replaced).
	public func clear() { set(false, text: nil) }

	// MARK: Start / stop

	private func start() {
		guard monitors.isEmpty else { return }
		if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
			self?.mouseDownPoint = NSEvent.mouseLocation
			_ = e
		}) { monitors.append(m) }
		if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in
			self?.mouseUp(clickCount: e.clickCount)
		}) { monitors.append(m) }
		if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp], handler: { [weak self] e in
			self?.keyUp(e)
		}) { monitors.append(m) }
		workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
			self?.scheduleCheck(hint: false, delay: 0.25)
		}
	}

	private func stop() {
		monitors.forEach { NSEvent.removeMonitor($0) }
		monitors.removeAll()
		if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
		workspaceObserver = nil
		pendingCheck?.cancel()
	}

	// MARK: Events

	private func mouseUp(clickCount: Int) {
		var dragged = false
		if let down = mouseDownPoint {
			let up = NSEvent.mouseLocation
			dragged = hypot(up.x - down.x, up.y - down.y) > 6
		}
		mouseDownPoint = nil
		// A drag or a double/triple click usually selects text.
		scheduleCheck(hint: dragged || clickCount >= 2, delay: 0.12)
	}

	private func keyUp(_ e: NSEvent) {
		let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
		let selectAll = flags.contains(.command) && e.charactersIgnoringModifiers?.lowercased() == "a"
		let shiftArrow = flags.contains(.shift) && [123, 124, 125, 126, 115, 119, 116, 121].contains(Int(e.keyCode))
		if selectAll || shiftArrow {
			scheduleCheck(hint: true, delay: 0.1)
		} else if hasSelection && !flags.contains(.command) {
			// Typing replaces / deselects the selection.
			scheduleCheck(hint: false, delay: 0.15)
		}
	}

	private func scheduleCheck(hint: Bool, delay: TimeInterval) {
		pendingCheck?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.check(hint: hint) }
		pendingCheck = work
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
	}

	// MARK: Accessibility

	private func check(hint: Bool) {
		guard AXIsProcessTrusted() else { set(false, text: nil); return }
		let front = NSWorkspace.shared.frontmostApplication
		// Our own windows (Writing Tools panel, settings) don't count.
		if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
		sourceApp = front
		if let pid = front?.processIdentifier { enableWebAccessibility(pid) }
		switch axSelection() {
		case .text(let text):
			set(true, text: text)
		case .none:
			set(false, text: nil)
		case .unknown:
			// App doesn't tell us: trust the gesture.
			set(hint, text: nil)
		}
	}

	private enum AXResult { case text(String), none, unknown }

	private func axSelection() -> AXResult {
		guard let element = SelectionBridge.focusedElement() else { return .unknown }
		var value: CFTypeRef?
		let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
		if err == .success {
			if let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return .text(text)
			}
			// Some apps return "" but still have a selected range.
			var range: CFTypeRef?
			if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
			   let range, CFGetTypeID(range) == AXValueGetTypeID() {
				var cf = CFRange(location: 0, length: 0)
				if AXValueGetValue(range as! AXValue, .cfRange, &cf), cf.length > 0 { return .unknown }
			}
			return .none
		}
		return .unknown
	}

	/// Chrome / Electron apps only build their accessibility tree when asked.
	private func enableWebAccessibility(_ pid: pid_t) {
		guard !enabledPIDs.contains(pid) else { return }
		enabledPIDs.insert(pid)
		if enabledPIDs.count > 64 { enabledPIDs.removeAll() }
		let app = AXUIElementCreateApplication(pid)
		AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
	}
}
