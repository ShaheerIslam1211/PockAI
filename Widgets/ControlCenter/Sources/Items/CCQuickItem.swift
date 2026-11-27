//
//  CCQuickItem.swift
//  TouchPlay
//
//  A Control Center button from TouchPlay's list (keyboard light, Wi-Fi, Bluetooth, dark mode, Screenshot,
//  Show Desktop…). Which ones show is set in the Control Center widget's settings.
//

import AppKit
import PockAIKit

class CCQuickItem: ControlCenterItem {

	let button: ControlCenterButtons.Button

	init(parentWidget: ControlCenterWidget?, button: ControlCenterButtons.Button) {
		self.button = button
		super.init(parentWidget: parentWidget)
	}

	override var enabled: Bool { button.isEnabled }

	override var title: String { button.id }

	override var icon: NSImage {
		let image = NSImage(systemSymbolName: button.currentSymbol(), accessibilityDescription: button.name)
			?? NSImage(systemSymbolName: button.symbol, accessibilityDescription: button.name)
		return image?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) ?? super.icon
	}

	override func action() -> Any? {
		let button = self.button
		if button.isSwitch {
			// Switching Wi-Fi / Bluetooth can take a moment: do it off the main thread, then redraw the icon.
			DispatchQueue.global(qos: .userInitiated).async {
				button.run()
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
					NSWorkspace.shared.notificationCenter.post(name: ControlCenterButtons.reloadNotification, object: nil)
				}
			}
		} else {
			button.run()
		}
		return nil
	}
}
