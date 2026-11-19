import AppKit
import PockKit
import PockAIKit

/// Subtitles of the video you're watching (browser extension, .srt files, or read from screen).
final class SubtitlesWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.Subtitles"
	var customizationLabel: String = "Subtitles"
	var view: NSView!
	private let subtitlesView = SubtitlesTouchBarView()

	required override init() {
		super.init()
		view = subtitlesView
		// Listen from creation: a collapsed (zero-width) widget never gets viewDidAppear.
		subtitlesView.start()
	}

	func viewDidAppear() { subtitlesView.start() }
	deinit { subtitlesView.stop() }
}
