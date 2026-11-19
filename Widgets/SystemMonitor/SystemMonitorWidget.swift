import AppKit
import Darwin
import PockKit
import PockAIKit

/// CPU, memory and network at a glance. Updates every 2 s only while visible. Tap: switch view.
final class SystemMonitorWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.SystemMonitor"
	var customizationLabel: String = "System Monitor"
	var view: NSView!

	private let content = TouchView(width: 190)
	private let line = LineView(frame: .zero)
	private var timer: Timer?
	private var lastTicks: (busy: UInt64, total: UInt64)?
	private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?
	private var showNetwork = UserDefaults.standard.bool(forKey: "pockai.sysmon.network")

	required override init() {
		super.init()
		content.layer?.cornerRadius = 6
		content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
		line.mainFont = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
		line.secondFont = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
		line.alignment = .center
		line.frame = NSRect(x: 4, y: 0, width: 182, height: 30)
		line.autoresizingMask = [.width, .height]
		content.addSubview(line)
		content.onTap = { [weak self] in
			guard let self else { return }
			self.showNetwork.toggle()
			UserDefaults.standard.set(self.showNetwork, forKey: "pockai.sysmon.network")
			self.update()
		}
		content.onLongPress = {
			NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
		}
		view = content
		update()
		settingsObserver = NotificationCenter.default.addObserver(forName: PockAIWidgetSettingsDidChange, object: nil, queue: .main) { [weak self] note in
			guard let self, (note.object as? String)?.hasPrefix("pockai.sysmon") ?? true else { return }
			self.showNetwork = UserDefaults.standard.bool(forKey: "pockai.sysmon.network")
			if self.timer != nil { self.viewDidAppear() } else { self.update() }
		}
	}

	private var settingsObserver: NSObjectProtocol?
	private var interval: Double { UserDefaults.standard.object(forKey: "pockai.sysmon.interval") as? Double ?? 2 }
	private var showBars: Bool { UserDefaults.standard.object(forKey: "pockai.sysmon.bars") as? Bool ?? true }

	func viewDidAppear() {
		timer?.invalidate()
		let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
		t.tolerance = 0.5
		RunLoop.main.add(t, forMode: .common)
		timer = t
		update()
	}

	func viewDidDisappear() {
		timer?.invalidate()
		timer = nil
	}

	deinit {
		timer?.invalidate()
		if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
	}

	private func update() {
		let cpu = cpuUsage()
		let (used, total) = memory()
		if showNetwork {
			let (down, up) = network()
			line.set("↓ \(Self.rate(down))   ↑ \(Self.rate(up))", lit: nil, second: String(format: "CPU %.0f%%", cpu))
		} else {
			line.set(String(format: "CPU %3.0f%%   RAM %.1f/%.0f GB", cpu, used, total), lit: nil,
					 second: showBars ? Self.bar(cpu / 100) + "  " + Self.bar(used / max(total, 1)) : "")
		}
	}

	private static func bar(_ fraction: Double) -> String {
		let n = Int((min(max(fraction, 0), 1) * 10).rounded())
		return String(repeating: "▮", count: n) + String(repeating: "▯", count: 10 - n)
	}

	private static func rate(_ bytesPerSecond: Double) -> String {
		let kb = bytesPerSecond / 1024
		return kb > 1024 ? String(format: "%.1f MB/s", kb / 1024) : String(format: "%.0f KB/s", kb)
	}

	// MARK: Readings

	private func cpuUsage() -> Double {
		var count: mach_msg_type_number_t = 0
		var info: processor_info_array_t?
		var cpus: natural_t = 0
		guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return 0 }
		defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
		var busy: UInt64 = 0, total: UInt64 = 0
		for i in 0..<Int(cpus) {
			let base = Int(CPU_STATE_MAX) * i
			let user = UInt64(info[base + Int(CPU_STATE_USER)]), system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
			let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
			busy += user + system + nice
			total += user + system + nice + idle
		}
		defer { lastTicks = (busy, total) }
		guard let last = lastTicks, total > last.total else { return 0 }
		return Double(busy - last.busy) / Double(total - last.total) * 100
	}

	private func memory() -> (usedGB: Double, totalGB: Double) {
		var stats = vm_statistics64()
		var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
		let result = withUnsafeMutablePointer(to: &stats) {
			$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
		}
		let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
		guard result == KERN_SUCCESS else { return (0, total) }
		let page = Double(vm_kernel_page_size)
		// "Used" like Activity Monitor: app memory + wired + compressed.
		let used = (Double(stats.internal_page_count) - Double(stats.purgeable_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
		return (used / 1_073_741_824, total)
	}

	private func network() -> (down: Double, up: Double) {
		var rx: UInt64 = 0, tx: UInt64 = 0
		var addrs: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
		defer { freeifaddrs(addrs) }
		var p: UnsafeMutablePointer<ifaddrs>? = first
		while let ifa = p {
			let name = String(cString: ifa.pointee.ifa_name)
			if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"), let data = ifa.pointee.ifa_data {
				let d = data.assumingMemoryBound(to: if_data.self).pointee
				rx += UInt64(d.ifi_ibytes)
				tx += UInt64(d.ifi_obytes)
			}
			p = ifa.pointee.ifa_next
		}
		let now = Date()
		defer { lastNet = (rx, tx, now) }
		guard let last = lastNet, rx >= last.rx, tx >= last.tx else { return (0, 0) }
		let dt = max(0.5, now.timeIntervalSince(last.at))
		return (Double(rx - last.rx) / dt, Double(tx - last.tx) / dt)
	}
}
