import AppKit
import PockKit
import PockAIKit

/// Purrbar's synced lyrics inside the Pock bar.
final class LyricsWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.Lyrics"
	var customizationLabel: String = "Lyrics"
	var view: NSView!
	private let lyricsView = LyricsTouchBarView()

	required override init() {
		super.init()
		view = lyricsView
		// Listen from creation: a collapsed (zero-width) widget never gets viewDidAppear.
		lyricsView.start()
	}

	func viewDidAppear() { lyricsView.start() }
	deinit { lyricsView.stop() }
}
