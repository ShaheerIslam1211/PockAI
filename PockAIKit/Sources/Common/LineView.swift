import AppKit

/// A light-weight one/two-line text view for the Touch Bar.
/// The first `lit` UTF-16 units of the main line are drawn bright (karaoke), the rest dimmed.
/// Long lines scroll so the part being sung (or read) always stays in view.
public final class LineView: NSView {

	public var mainFont = NSFont.systemFont(ofSize: 14, weight: .semibold) { didSet { needsDisplay = true } }
	public var secondFont = NSFont.systemFont(ofSize: 9, weight: .medium) { didSet { needsDisplay = true } }
	public var litColor = NSColor.white { didSet { needsDisplay = true } }
	public var dimColor = NSColor(white: 1, alpha: 0.42) { didSet { needsDisplay = true } }
	public var secondColor = NSColor(white: 1, alpha: 0.55) { didSet { needsDisplay = true } }
	public var alignment: NSTextAlignment = .left { didSet { needsDisplay = true } }

	private var main = ""
	private var lit = 0
	private var second = ""
	private var offset: CGFloat = 0
	private var targetOffset: CGFloat = 0

	public override var isFlipped: Bool { false }
	public override var allowsVibrancy: Bool { false }

	public override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.masksToBounds = true
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
	}

	/// Set the text. `lit = nil` means the whole main line is bright.
	public func set(_ text: String, lit: Int? = nil, second: String = "") {
		let length = (text as NSString).length
		let newLit = min(length, max(0, lit ?? length))
		guard text != main || newLit != lit || second != self.second else { return }
		if text != main { offset = 0 }
		main = text
		self.lit = newLit
		self.second = second
		updateOffset()
		needsDisplay = true
	}

	private var hasSecond: Bool { !second.isEmpty }

	private func mainAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
		[.font: hasSecond ? mainFont.withSize(max(10, mainFont.pointSize - 2)) : mainFont, .foregroundColor: color]
	}

	private func updateOffset() {
		let full = (main as NSString).size(withAttributes: mainAttributes(litColor)).width
		let available = bounds.width - 4
		guard full > available, available > 0 else { targetOffset = 0; offset = 0; return }
		let litWidth = ((main as NSString).substring(to: lit) as NSString).size(withAttributes: mainAttributes(litColor)).width
		// Keep the end of the bright part at ~65% of the width.
		targetOffset = min(full - available, max(0, litWidth - available * 0.65))
		// Ease towards the target so the text glides instead of jumping.
		offset += (targetOffset - offset) * 0.5
		if abs(targetOffset - offset) < 1 { offset = targetOffset }
	}

	public override func draw(_ dirtyRect: NSRect) {
		let ns = main as NSString
		let attributed = NSMutableAttributedString(string: main, attributes: mainAttributes(dimColor))
		if lit > 0 { attributed.addAttributes([.foregroundColor: litColor], range: NSRange(location: 0, length: min(lit, ns.length))) }
		let size = attributed.size()
		let mainY: CGFloat
		if hasSecond {
			mainY = bounds.height - size.height - 1
		} else {
			mainY = (bounds.height - size.height) / 2
		}
		var x: CGFloat = 2 - offset
		if size.width <= bounds.width - 4 {
			switch alignment {
			case .center: x = (bounds.width - size.width) / 2
			case .right: x = bounds.width - size.width - 2
			default: x = 2
			}
		}
		attributed.draw(at: NSPoint(x: x, y: mainY))
		if hasSecond {
			let sec = NSAttributedString(string: second, attributes: [.font: secondFont, .foregroundColor: secondColor])
			let sw = sec.size().width
			var sx: CGFloat = 2
			if sw <= bounds.width - 4 {
				switch alignment {
				case .center: sx = (bounds.width - sw) / 2
				case .right: sx = bounds.width - sw - 2
				default: sx = 2
				}
			}
			sec.draw(at: NSPoint(x: sx, y: 1))
		}
	}

	public override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		updateOffset()
	}
}
