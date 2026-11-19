import AppKit
import ScreenCaptureKit
import Vision

/// Optional: reads burned-in or on-screen subtitles from the lower part of the video window with
/// on-device text recognition (Vision). Works with any app (Netflix in Safari, the TV app, games…).
/// Runs only while something is playing, at 2 frames a second, on a small crop: light on CPU.
/// Needs Screen Recording permission (asked the first time).
final class ScreenSubtitleReader {

	private var sink: ((String, SubtitleCenter.Source, String) -> Void)?
	private var npToken: UUID?
	private var timer: Timer?
	private var busy = false
	private var lastText = ""
	private var playing = false
	private var appName = ""

	func start(_ sink: @escaping (String, SubtitleCenter.Source, String) -> Void) {
		self.sink = sink
		guard npToken == nil else { return }
		// Screenshots of a single window need ScreenCaptureKit's screenshot API (macOS 14+).
		guard #available(macOS 14.0, *) else { return }
		if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
		npToken = NowPlayingCenter.shared.subscribe { [weak self] s, _ in
			guard let self else { return }
			self.playing = s.playing && s.hasContent
			self.appName = NowPlayingCenter.appName(s.app) ?? "Screen"
			self.restartTimer()
		}
	}

	func stop() {
		NowPlayingCenter.shared.unsubscribe(npToken)
		npToken = nil
		timer?.invalidate(); timer = nil
	}

	private func restartTimer() {
		timer?.invalidate(); timer = nil
		guard playing, CGPreflightScreenCaptureAccess() else { return }
		let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.capture() }
		t.tolerance = 0.15
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	private func capture() {
		guard !busy else { return }
		busy = true
		Task { [weak self] in
			defer { DispatchQueue.main.async { self?.busy = false } }
			guard let self, #available(macOS 14.0, *), let image = await self.grabFrontWindowBottom() else { return }
			let text = Self.recognize(image)
			DispatchQueue.main.async {
				guard text != self.lastText else { return }
				self.lastText = text
				self.sink?(text, .screen, self.appName)
			}
		}
	}

	/// Bottom 28% of the frontmost app's largest on-screen window (where subtitles live).
	@available(macOS 14.0, *)
	private func grabFrontWindowBottom() async -> CGImage? {
		guard let content = await Self.shareableContent() else { return nil }
		let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
		let windows = content.windows.filter { $0.owningApplication?.processID == frontPID && $0.windowLayer == 0 && $0.frame.width > 320 }
		guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
		let filter = SCContentFilter(desktopIndependentWindow: window)
		let config = SCStreamConfiguration()
		let crop = CGRect(x: 0, y: window.frame.height * 0.72, width: window.frame.width, height: window.frame.height * 0.28)
		config.sourceRect = crop
		// Half resolution is plenty for subtitle-sized text and keeps memory low.
		config.width = Int(crop.width)
		config.height = Int(crop.height)
		config.showsCursor = false
		return await Self.capture(filter, config)
	}

	// ScreenCaptureKit's async wrappers trap (crash) when Apple's completion handler reports neither a
	// result nor an error, which happens on macOS 15 (e.g. a window closing mid-capture). Use the
	// callback APIs and resume exactly once, treating "nothing" as "no frame".

	@available(macOS 14.0, *)
	private static func shareableContent() async -> SCShareableContent? {
		await withCheckedContinuation { (cont: CheckedContinuation<SCShareableContent?, Never>) in
			let once = Once()
			SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
				once.run { cont.resume(returning: content) }
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.run { cont.resume(returning: nil) } }
		}
	}

	@available(macOS 14.0, *)
	private static func capture(_ filter: SCContentFilter, _ config: SCStreamConfiguration) async -> CGImage? {
		await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
			let once = Once()
			SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
				once.run { cont.resume(returning: image) }
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.run { cont.resume(returning: nil) } }
		}
	}

	private static func recognize(_ image: CGImage) -> String {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .fast
		request.usesLanguageCorrection = true
		request.minimumTextHeight = 0.08
		let handler = VNImageRequestHandler(cgImage: image, options: [:])
		guard (try? handler.perform([request])) != nil, let results = request.results else { return "" }
		// Subtitles are centred: keep lines whose box centre is near the middle, top to bottom.
		let lines = results
			.filter { abs($0.boundingBox.midX - 0.5) < 0.3 && $0.confidence > 0.4 }
			.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
			.compactMap { $0.topCandidates(1).first?.string }
		return lines.prefix(3).joined(separator: "\n")
	}
}

/// Runs its block at most once, from any thread.
private final class Once {
	private var done = false
	private let lock = NSLock()
	func run(_ block: () -> Void) {
		lock.lock()
		let first = !done
		done = true
		lock.unlock()
		if first { block() }
	}
}
