import AppKit
import PockKit
import PockAIKit

/// Focus timer (Pomodoro). Tap: start / pause. Swipe right / left: ±5 minutes. Long press: reset.
/// When it finishes it chimes and flashes; the time is remembered between Touch Bar reloads.
final class TimerWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.Timer"
	var customizationLabel: String = "Timer"
	var view: NSView!

	private let content = TouchView(width: 104)
	private let line = LineView(frame: .zero)
	private let progress = CALayer()
	private var tick: Timer?

	private let d = UserDefaults.standard
	/// Chosen length in seconds.
	private var length: Double {
		get { d.object(forKey: "pockai.timer.length") as? Double ?? 25 * 60 }
		set { d.set(min(max(newValue, 60), 3 * 3600), forKey: "pockai.timer.length") }
	}
	/// When running: the end date. When paused: nil and `remaining` holds the time left.
	private var endDate: Date? {
		get { d.object(forKey: "pockai.timer.end") as? Date }
		set { d.set(newValue, forKey: "pockai.timer.end") }
	}
	private var paused: Double? {
		get { d.object(forKey: "pockai.timer.paused") as? Double }
		set { d.set(newValue, forKey: "pockai.timer.paused") }
	}

	required override init() {
		super.init()
		content.layer?.cornerRadius = 6
		content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
		progress.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
		content.layer?.addSublayer(progress)
		line.mainFont = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
		line.alignment = .center
		line.frame = NSRect(x: 0, y: 0, width: 104, height: 30)
		line.autoresizingMask = [.width, .height]
		content.addSubview(line)
		content.onTap = { [weak self] in self?.toggle() }
		content.onLongPress = { [weak self] in self?.reset() }
		content.onSwipeRight = { [weak self] in self?.adjust(+300) }
		content.onSwipeLeft = { [weak self] in self?.adjust(-300) }
		view = content
		startTicking()
		render()
	}

	deinit { tick?.invalidate() }

	private var remaining: Double {
		if let end = endDate { return max(0, end.timeIntervalSinceNow) }
		return paused ?? length
	}

	private var running: Bool { endDate != nil }

	private func toggle() {
		if let end = endDate {
			paused = max(0, end.timeIntervalSinceNow)
			endDate = nil
		} else {
			endDate = Date().addingTimeInterval(paused ?? length)
			paused = nil
		}
		render()
	}

	private func reset() {
		endDate = nil
		paused = nil
		render()
	}

	private func adjust(_ delta: Double) {
		if let end = endDate {
			endDate = Date(timeIntervalSince1970: max(Date().timeIntervalSince1970 + 60, end.timeIntervalSince1970 + delta))
		} else if let p = paused {
			paused = max(60, p + delta)
		} else {
			length += delta
		}
		render()
	}

	private func startTicking() {
		let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.render() }
		t.tolerance = 0.2
		RunLoop.main.add(t, forMode: .common)
		tick = t
	}

	private func render() {
		let left = remaining
		if running && left <= 0 {
			endDate = nil
			paused = nil
			finished()
			return
		}
		let m = Int(left) / 60, s = Int(left) % 60
		let text = (m >= 60 ? String(format: "%d:%02d:%02d", m / 60, m % 60, s) : String(format: "%02d:%02d", m, s))
		line.set((running ? "⏱ " : "⏸ ") + text, lit: nil)
		let total = max(1, paused != nil || running ? max(length, left) : length)
		CATransaction.begin(); CATransaction.setDisableActions(true)
		progress.frame = CGRect(x: 0, y: 0, width: content.bounds.width * CGFloat(1 - left / total), height: 30)
		progress.isHidden = !running && paused == nil
		CATransaction.commit()
	}

	private func finished() {
		let sound = d.string(forKey: "pockai.timer.sound") ?? "Glass"
		if sound != "None" { NSSound(named: NSSound.Name(sound))?.play() }
		line.set("✓ Time's up!", lit: nil)
		guard d.object(forKey: "pockai.timer.flash") as? Bool ?? true else { render(); return }
		var flashes = 0
		Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] t in
			guard let self, flashes < 8 else { t.invalidate(); self?.render(); return }
			flashes += 1
			self.content.layer?.backgroundColor = (flashes % 2 == 0 ? NSColor(white: 0.12, alpha: 1) : NSColor.systemOrange).cgColor
		}
	}
}
