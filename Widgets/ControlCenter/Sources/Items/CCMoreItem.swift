//
//  CCMoreItem.swift
//  TouchPlay
//
//  ⊞ at the end of the Control Center widget: opens the full Control Center panel (Wi-Fi, Bluetooth,
//  dark mode, Night Shift, keep awake, mic, sliders, Show Desktop, Lock, Sleep…).
//

import AppKit
import PockAIKit

class CCMoreItem: ControlCenterItem {

	override var enabled: Bool { UserDefaults.standard.object(forKey: "touchplay.cc.more") as? Bool ?? true }

	override var title: String { "more" }

	override var icon: NSImage {
		NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "More controls")?
			.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) ?? super.icon
	}

	override func action() -> Any? {
		ControlPanel.open()
		return nil
	}
}
