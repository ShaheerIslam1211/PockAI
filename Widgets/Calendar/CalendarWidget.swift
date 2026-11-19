import AppKit
import EventKit
import PockKit
import PockAIKit

/// Your next calendar event today: "⏰ 15:00 Standup · in 25m". Tap: open Calendar.
/// Refreshes every minute and whenever your calendars change. Hides when there's nothing left today.
final class CalendarWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.Calendar"
	var customizationLabel: String = "Next Event"
	var view: NSView!

	private let content = TouchView(width: 220)
	private let line = LineView(frame: .zero)
	private let store = EKEventStore()
	private var timer: Timer?
	private var observer: NSObjectProtocol?
	private var granted = false

	required override init() {
		super.init()
		content.layer?.cornerRadius = 6
		content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
		line.mainFont = .systemFont(ofSize: 12, weight: .semibold)
		line.secondFont = .systemFont(ofSize: 9, weight: .medium)
		line.frame = NSRect(x: 6, y: 0, width: 208, height: 30)
		line.autoresizingMask = [.width, .height]
		content.addSubview(line)
		content.onTap = { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
		view = content
		line.set("📅 Calendar", lit: nil, second: "Tap to allow access")
		requestAccess()
		settingsObserver = NotificationCenter.default.addObserver(forName: PockAIWidgetSettingsDidChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
	}

	private var settingsObserver: NSObjectProtocol?
	private var d: UserDefaults { .standard }

	deinit {
		timer?.invalidate()
		if let observer { NotificationCenter.default.removeObserver(observer) }
		if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
	}

	private func requestAccess() {
		let done: (Bool) -> Void = { [weak self] ok in
			DispatchQueue.main.async {
				guard let self else { return }
				self.granted = ok
				if ok { self.start() } else { self.line.set("📅 No calendar access", lit: nil, second: "System Settings → Privacy → Calendars") }
			}
		}
		if #available(macOS 14.0, *) {
			store.requestFullAccessToEvents { ok, _ in done(ok) }
		} else {
			store.requestAccess(to: .event) { ok, _ in done(ok) }
		}
	}

	private func start() {
		observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.refresh() }
		let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
		t.tolerance = 10
		RunLoop.main.add(t, forMode: .common)
		timer = t
		refresh()
	}

	private func refresh() {
		guard granted else { return }
		let now = Date()
		let end = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
		let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60 * 30), end: end, calendars: nil)
		let next = store.events(matching: predicate)
			.filter { (d.bool(forKey: "pockai.calendar.allDay") || !$0.isAllDay) && $0.endDate > now }
			.sorted { $0.startDate < $1.startDate }
			.first
		guard let event = next else {
			line.set("📅 Nothing else today", lit: nil)
			content.setCollapsed(UserDefaults.standard.object(forKey: "pockai.calendar.hideEmpty") as? Bool ?? false)
			return
		}
		content.setCollapsed(false)
		let time = DateFormatter.localizedString(from: event.startDate, dateStyle: .none, timeStyle: .short)
		let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
		let when: String
		if minutes <= 0 { when = "now" }
		else if minutes < 60 { when = "in \(minutes)m" }
		else { when = "in \(minutes / 60)h \(minutes % 60)m" }
		let showLocation = d.object(forKey: "pockai.calendar.location") as? Bool ?? true
		let label = event.isAllDay ? "All day" : time
		line.set("⏰ \(label)  \(event.title ?? "Event")", lit: nil, second: when + (showLocation ? (event.location.map { " · \($0)" } ?? "") : ""))
		let warn = d.object(forKey: "pockai.calendar.warn") as? Int ?? 10
		content.layer?.backgroundColor = (warn > 0 && minutes <= warn ? NSColor.systemRed.withAlphaComponent(0.45) : NSColor(white: 0.12, alpha: 1)).cgColor
	}
}
