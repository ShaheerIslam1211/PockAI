//
//  AppTouchBarSwitcher.swift
//  PockAI
//
//  Lets every app keep its own Touch Bar (Safari, Chrome, Music, Photos, Photoshop, Word, Excel…):
//
//  • The first button on PockAI's bar shows the app you're in. Tap it → PockAI steps aside and
//    the app's own controls appear (exactly what macOS would show without PockAI).
//  • A PockAI button sits in the Control Strip. Tap it → PockAI comes back.
//  • The choice is remembered per app, so switching windows switches the Touch Bar too:
//    Chrome → Chrome's controls, Finder → PockAI, Music → Music's controls…
//  • Apps known for good Touch Bar controls start in "app controls" (editable in
//    PockAI Settings → Touch Bar). Everything else starts with PockAI.
//
//  PockAI never steps aside while one of its own full-bar screens (AI, games, player) is open.
//

import AppKit
import PockAIKit

final class AppTouchBarSwitcher: NSObject {

	static let shared = AppTouchBarSwitcher()
	static let trayIdentifier = "com.pockai.tray"
	static let buttonWidth: CGFloat = 44

	// MARK: Settings (PockAI Settings → Touch Bar)

	static var showsAppButton: Bool { AppControlsSettings.showsAppButton }
	static var followsApps: Bool { AppControlsSettings.followsApps }
	/// Per-app Touch Bars in use (button on the bar or automatic switching).
	static var isActive: Bool { followsApps || showsAppButton }
	private var choices: [String: String] {
		get { AppControlsSettings.choices }
		set { AppControlsSettings.choices = newValue }
	}

	// MARK: State

	private(set) lazy var appButton: NSButton = {
		let button = NSButton(image: Self.sized(NSApp.applicationIconImage, 24), target: self, action: #selector(showAppControls))
		button.imagePosition = .imageOnly
		button.imageScaling = .scaleProportionallyDown
		button.bezelColor = NSColor(white: 0.22, alpha: 1)
		button.translatesAutoresizingMaskIntoConstraints = false
		button.widthAnchor.constraint(equalToConstant: Self.buttonWidth).isActive = true
		button.heightAnchor.constraint(equalToConstant: 30).isActive = true
		return button
	}()
	private lazy var trayItem: NSCustomTouchBarItem = {
		let item = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier(Self.trayIdentifier))
		item.view = TrayIconView(image: NSApp.applicationIconImage) { [weak self] in self?.trayTapped() }
		item.customizationLabel = "PockAI"
		return item
	}()
	/// True while PockAI is hidden because of this switcher (so it only brings back what it hid).
	private(set) var steppedAside = false
	private var frontApp: NSRunningApplication?

	// MARK: Start

	func start() {
		assertTrayPresence()
		NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appDidActivate(_:)),
														  name: NSWorkspace.didActivateApplicationNotification, object: nil)
		NotificationCenter.default.addObserver(forName: PockAIWidgetSettingsDidChange, object: nil, queue: .main) { [weak self] note in
			guard (note.object as? String)?.hasPrefix("pockai.apps") ?? false else { return }
			self?.settingsChanged()
		}
		if let app = NSWorkspace.shared.frontmostApplication { track(app) }
	}

	func removeTray() {
		NSTouchBarItem.removeSystemTrayItem(trayItem)
		if let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
		   let fn = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") {
			typealias SetPresence = @convention(c) (CFString, Bool) -> Void
			unsafeBitCast(fn, to: SetPresence.self)(Self.trayIdentifier as CFString, false)
		}
	}

	/// Puts the PockAI button in the Control Strip (again after the Control Strip restarts).
	func assertTrayPresence() {
		NSTouchBarItem.addSystemTrayItem(trayItem)
		// Private DFRFoundation call, resolved at runtime (not exported for linking).
		if let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW),
		   let fn = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") {
			typealias SetPresence = @convention(c) (CFString, Bool) -> Void
			unsafeBitCast(fn, to: SetPresence.self)(Self.trayIdentifier as CFString, true)
		}
	}

	// MARK: Actions

	/// Front-app button on PockAI's bar.
	@objc func showAppControls() {
		guard let id = frontApp?.bundleIdentifier else { return }
		choices[id] = "app"
		stepAside()
	}

	/// PockAI button in the Control Strip: toggles between the app's controls and PockAI.
	@objc func trayTapped() {
		if steppedAside || AppController.shared.isVisible == false {
			if let id = frontApp?.bundleIdentifier { choices[id] = "pock" }
			comeBack(force: true)
		} else {
			showAppControls()
		}
	}

	func resetChoices() { choices = [:] }

	/// ⌃⌃ (double Control) and the menu bar item: PockAI ↔ the app's own controls, remembered for this app.
	/// Returns false when the switcher isn't involved (PockAI then handles the toggle as before).
	@discardableResult func toggleFromShortcut() -> Bool {
		if steppedAside {
			if let id = frontApp?.bundleIdentifier { choices[id] = "pock" }
			comeBack(force: true)
			return true
		}
		guard AppController.shared.isVisible, frontApp?.bundleIdentifier != nil else { return false }
		showAppControls()
		return steppedAside
	}

	// MARK: Following apps

	@objc private func appDidActivate(_ note: Notification) {
		guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
		// PockAI's own windows (settings, panels) don't change anything.
		guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
		track(app)
		guard Self.followsApps else { return }
		// Give the app a moment to install its own Touch Bar before PockAI steps aside.
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
			guard let self, self.frontApp == app else { return }
			self.apply(for: app)
		}
	}

	private func track(_ app: NSRunningApplication) {
		frontApp = app
		if let icon = app.icon { appButton.image = Self.sized(icon, 24) }
		appButton.toolTip = app.localizedName.map { "Show \($0)'s Touch Bar" }
	}

	private func wantsAppControls(_ app: NSRunningApplication) -> Bool {
		guard let id = app.bundleIdentifier else { return false }
		if let choice = choices[id] { return choice == "app" }
		return AppControlsSettings.automaticApps.contains(id)
	}

	private func apply(for app: NSRunningApplication) {
		if wantsAppControls(app) {
			stepAside()
		} else {
			comeBack(force: false)
		}
	}

	private func settingsChanged() {
		guard let app = frontApp else { return }
		if Self.followsApps { apply(for: app) } else { comeBack(force: false) }
		// The app button is part of the bar: rebuild it when it's switched on/off.
		if AppController.shared.isVisible {
			AppController.shared.pockTouchBarController?.minimize()
			AppController.shared.pockTouchBarController?.present()
		}
	}

	/// Hide PockAI so the frontmost app's own Touch Bar shows.
	private func stepAside() {
		let controller = AppController.shared
		guard controller.isLocked == false, controller.isVisible,
			  let nav = controller.navigationController, nav.childControllers.count <= 1,
			  PurrPlayer.shared.isPresented == false else { return }
		steppedAside = true
		nav.minimize()
		assertTrayPresence()
	}

	/// Bring PockAI back (only if this switcher hid it, unless the user asked for it).
	private func comeBack(force: Bool) {
		let controller = AppController.shared
		guard force || steppedAside, controller.isLocked == false, controller.isVisible == false,
			  let nav = controller.navigationController else { return }
		steppedAside = false
		nav.deminimize()
	}

	private static func sized(_ image: NSImage, _ side: CGFloat) -> NSImage {
		let out = NSImage(size: NSSize(width: side, height: side))
		out.lockFocus()
		image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
		out.unlockFocus()
		return out
	}
}


/// The PockAI button in the Control Strip. The Control Strip shows this view from another process and
/// never asks it to draw, so a normal NSButton appears as an empty grey box. The icon is put straight
/// into the layer instead, and taps come from a gesture recogniser.
private final class TrayIconView: NSView {
	private let onTap: () -> Void

	init(image: NSImage, onTap: @escaping () -> Void) {
		self.onTap = onTap
		super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 30))
		wantsLayer = true
		layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
		layer?.cornerRadius = 6
		let iconLayer = CALayer()
		iconLayer.frame = CGRect(x: (44 - 24) / 2, y: 3, width: 24, height: 24)
		iconLayer.contentsGravity = .resizeAspect
		iconLayer.contentsScale = 2
		var rect = CGRect(x: 0, y: 0, width: 48, height: 48)
		iconLayer.contents = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
		layer?.addSublayer(iconLayer)
		translatesAutoresizingMaskIntoConstraints = false
		widthAnchor.constraint(equalToConstant: 44).isActive = true
		heightAnchor.constraint(equalToConstant: 30).isActive = true
		let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
		click.allowedTouchTypes = .direct
		addGestureRecognizer(click)
		toolTip = "PockAI"
	}

	required init?(coder: NSCoder) { nil }

	override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 30) }

	@objc private func tapped() { onTap() }

	override func touchesBegan(with event: NSEvent) {
		layer?.backgroundColor = NSColor(white: 0.4, alpha: 1).cgColor
	}

	override func touchesEnded(with event: NSEvent) {
		layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
	}

	override func touchesCancelled(with event: NSEvent) {
		layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
	}
}
