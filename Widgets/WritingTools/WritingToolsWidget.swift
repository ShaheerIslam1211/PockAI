import AppKit
import PockKit
import PockAIKit

/// ✨ appears when text is selected; tap for Proofread, Summary, Key Points… on the Touch Bar.
final class WritingToolsWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.WritingTools"
	var customizationLabel: String = "AI Writing Tools"
	var view: NSView!
	private let toolsView = WritingToolsTouchBarView()

	required override init() {
		super.init()
		view = toolsView
		// Listen from creation: a collapsed (zero-width) widget never gets viewDidAppear.
		toolsView.start()
	}

	var imageForCustomization: NSImage {
		NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Writing Tools") ?? NSImage()
	}

	func viewDidAppear() { toolsView.start() }
	deinit { toolsView.stop() }
}
