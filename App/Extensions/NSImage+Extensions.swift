//
//  NSImage+Extensions.swift
//  Pock
//
//  Created by Pierluigi Galdi on 09/03/21.
//

import Foundation
import AppKit

extension NSImage.Name {
	static var pockInnerIcon = NSImage.Name("pock-inner-icon")
	static var widgetIcon = NSImage.Name("widget-icon")
}

extension NSImage {
	/// Menu bar icon: a rounded "Touch Bar" frame with a play triangle (template, follows light/dark).
	static let touchPlayMenuBarIcon: NSImage = {
		let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
			NSColor.black.set()
			let frame = NSBezierPath(roundedRect: NSRect(x: 1, y: 2.5, width: 18, height: 11), xRadius: 3, yRadius: 3)
			frame.lineWidth = 1.5
			frame.stroke()
			let play = NSBezierPath()
			play.move(to: NSPoint(x: 8, y: 5))
			play.line(to: NSPoint(x: 13.5, y: 8))
			play.line(to: NSPoint(x: 8, y: 11))
			play.close()
			play.fill()
			return true
		}
		image.isTemplate = true
		return image
	}()

	/// Returns an NSImage snapshot of the passed view in 2x resolution.
	convenience init?(frame: NSRect, view: NSView) {
		guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: frame) else {
			return nil
		}
		self.init()
		view.cacheDisplay(in: frame, to: bitmapRep)
		addRepresentation(bitmapRep)
		bitmapRep.size = frame.size
	}
}
