//
//  CompactCustomizationItem.swift
//  PockAI
//
//  In scroll mode the bar can hold any number of widgets, but macOS's Customize screen still
//  lays them out at their real width and throws widgets out once the physical bar is full.
//  While customising, each widget is therefore shown on the Touch Bar as a small icon chip
//  (~40 pt), so all of them fit and nothing gets removed. The palette on the Mac screen keeps
//  showing the real widget preview with its name.
//

import AppKit

internal final class CompactCustomizationItem: NSCustomTouchBarItem {

	private var paletteView: NSView?
	private var label: String = ""

	override var customizationLabel: String! {
		get { label }
		set { label = newValue ?? "" }
	}

	convenience init(widgetItem: PKWidgetTouchBarItem) {
		self.init(identifier: widgetItem.identifier)
		label = widgetItem.customizationLabel ?? widgetItem.identifier.rawValue
		paletteView = widgetItem.viewForCustomizationPalette()
		view = Self.chip(for: widgetItem.identifier.rawValue, label: label)
	}

	override func viewForCustomizationPalette() -> NSView {
		return paletteView ?? view
	}

	override func viewForCustomizationPreview() -> NSView {
		return Self.chip(for: identifier.rawValue, label: label)
	}

	// MARK: Chip

	private static let symbols: [String: String] = [
		"com.pigigaldi.pock.Esc": "escape",
		"com.pigigaldi.pock.Dock": "dock.rectangle",
		"com.pigigaldi.pock.Status": "battery.75",
		"com.pigigaldi.pock.ControlCenter": "slider.horizontal.3",
		"com.pigigaldi.pock.NowPlaying": "play.circle",
		"com.pigigaldi.pock.Weather": "cloud.sun",
		"com.pockai.widget.Lyrics": "music.note",
		"com.pockai.widget.WritingTools": "sparkles",
		"com.pockai.widget.Subtitles": "captions.bubble",
		"com.pockai.widget.SystemMonitor": "cpu",
		"com.pockai.widget.Clipboard": "doc.on.clipboard",
		"com.pockai.widget.Timer": "timer",
		"com.pockai.widget.QuickActions": "bolt",
		"com.pockai.widget.Calendar": "calendar",
		"com.pockai.widget.Games": "gamecontroller"
	]

	static func chip(for identifier: String, label: String) -> NSView {
		let width: CGFloat = 44
		let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
		container.wantsLayer = true
		container.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
		container.layer?.cornerRadius = 6
		container.translatesAutoresizingMaskIntoConstraints = false
		container.widthAnchor.constraint(equalToConstant: width).isActive = true
		container.heightAnchor.constraint(equalToConstant: 30).isActive = true

		let content: NSView
		if let name = symbols[identifier],
		   let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
				?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: label) {
			let imageView = NSImageView(image: image)
			imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
			imageView.contentTintColor = .white
			content = imageView
		} else {
			// Third-party widget: first letters of its name.
			let initials = label.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
			let text = NSTextField(labelWithString: initials.isEmpty ? "?" : initials.uppercased())
			text.font = .systemFont(ofSize: 12, weight: .bold)
			text.textColor = .white
			text.alignment = .center
			content = text
		}
		content.translatesAutoresizingMaskIntoConstraints = false
		container.addSubview(content)
		NSLayoutConstraint.activate([
			content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
			content.centerYAnchor.constraint(equalTo: container.centerYAnchor)
		])
		container.toolTip = label
		return container
	}
}
