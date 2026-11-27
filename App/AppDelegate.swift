//
//  AppDelegate.swift
//  Pock
//
//  Created by Pierluigi Galdi on 09/03/21.
//

import Cocoa
import PockAIKit
import PockKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {

	/// MenuBar item and menu
	private let mainBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
	private let mainBarMenu = NSMenu(title: "TouchPlay")
	
	private var preferencesMenuItem: NSMenuBadgeItem!
	private var manageWidgetsMenuItem: NSMenuBadgeItem!

	func applicationWillFinishLaunching(_ notification: Notification) {
		/// The app used to be called PockAI: bring its settings over and retire the old copy.
		RenameMigration.run()
		/// Single instance + launchd watchdog (auto-restart after a crash, start at login).
		if Watchdog.startup() {
			exit(0)
		}
	}

	func applicationDidFinishLaunching(_ aNotification: Notification) {
		/// Set Roger allowed log levels
		#if DEBUG
        Roger.allowedLevels = [.error, .debug, .info]
		#else
		Roger.allowedLevels = []
		#endif
		
		/// Crash guard: log uncaught exceptions instead of silently dying, and remember the last crash.
		CrashGuard.install()

		/// Register the PockAI Control Strip button before the first bar is presented (it's that bar's tray item).
		AppTouchBarSwitcher.shared.start()
		TypingSuggestions.shared.start()
		ControlPanel.registerHook()

		/// Add main bar menu item
		addMainBarItem()

		/// Test / automation hooks (like Purrbar's): local.pockai.ai.open, local.pockai.purr.show …
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.ai.open"), object: nil, queue: .main) { note in
			WritingToolsBar.present(source: (note.object as? String) ?? "", target: nil)
		}

		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.ai.run"), object: nil, queue: .main) { note in
			WritingToolsBar.runOnCurrent(modeNamed: (note.object as? String) ?? "fix")
		}

		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.player.open"), object: nil, queue: .main) { _ in
			PurrPlayer.shared.show(lyrics: true)
		}

		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.settings"), object: nil, queue: .main) { _ in
			PockAISettings.open()
		}
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.customize"), object: nil, queue: .main) { _ in
			AppController.shared.openPockCustomizationPalette()
		}
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.customize.close"), object: nil, queue: .main) { _ in
			NSApp.toggleTouchBarCustomizationPalette(nil)
		}

		/// Self-test: build every widget's settings page and log whether it loaded (catches broken panes).
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.selftest.panes"), object: nil, queue: .main) { _ in
			for widget in WidgetsLoader.installedWidgets {
				guard let clss = widget.preferencesClass as? PKWidgetPreference.Type else {
					NSLog("[TouchPlay][pane] \(widget.name): no settings")
					continue
				}
				let pane = clss.init(nibName: clss.nibName, bundle: Bundle(for: clss))
				let size = pane.view.fittingSize
				NSLog("[TouchPlay][pane] \(widget.name): OK \(Int(size.width))x\(Int(size.height))")
			}
			AppController.shared.openController(WidgetsManagerViewController())
		}

		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.selftest.select"), object: nil, queue: .main) { note in
			let manager = NSApp.windows.compactMap { $0.contentViewController as? WidgetsManagerViewController }.first
			manager?.select(widgetNamed: (note.object as? String) ?? "")
		}

		/// PockAI: system-wide Writing Tools shortcut (⌃⌥W)
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.tray"), object: nil, queue: .main) { note in
			if (note.object as? String) == "assert" { AppTouchBarSwitcher.shared.assertTrayPresence() } else if (note.object as? String) == "off" { AppTouchBarSwitcher.shared.removeTray() } else { AppTouchBarSwitcher.shared.trayTapped() }
		}
		AIHotKey.register { Task { @MainActor in await WritingToolsController.shared.show() } }

		/// Register for notifications
		NotificationCenter.default.addObserver(self, selector: #selector(updateMenuItemsAfterLatestVersionsFetch), name: .didFetchLatestVersions, object: nil)
		
		/// Load installed widgets and prepare touch bar
		AppController.shared.reloadWidgets {
			AppController.shared.fetchLatestVersions { [weak self] in
                let currentVersion = Updater.fullAppVersion
                if let core = Updater.cachedLatestReleases?.core, core.name.isGreatherThan(currentVersion) {
                    self?.openPreferences()
                }
            }
			AppController.shared.prepareTouchBar()
		}

		/// Deactivate Pock
		NSApp.deactivate()
		
		/// Show On-Board window, if needed
		if Preferences[.didShowOnBoard] == false {
			openOnBoardController()
		}

	}
	
	func applicationWillTerminate(_ notification: Notification) {
		/// Tear down Pock to be sure to reset user defined Touch Bar settings.
		PurrPlayer.shared.shutdown()
		AppController.shared.tearDownTouchBar()
	}

	// MARK: Setup main bar menu items
	private func addMainBarItem() {
		if let button = mainBarItem.button {
			button.image = NSImage.touchPlayMenuBarIcon
			/// Create menu
			setupMainBarMenuItems()
			mainBarItem.menu = mainBarMenu
		}
	}
	
	// MARK: Advanced menu
	private lazy var advancedMenuItem: NSMenuItem = {
		let menu = NSMenu(title: "menu.advanced".localized)
		menu.addItem(NSMenuHeader.new(title: "menu.widgets".localized))
		menu.addItem(NSMenuItemCustomView.new(
			title: "menu.advanced.re-install-default-widgets".localized,
			target: self,
			selector: #selector(selectAdvancedSectionItem(_:)),
			keyEquivalent: "w"
		))
        menu.addItem(NSMenuItemCustomView.new(
            title: "menu.advanced.open-widgets-folder".localized,
            target: self,
            selector: #selector(selectAdvancedSectionItem(_:)),
            keyEquivalent: "f"
        ))
		menu.addItem(NSMenuHeader.new(title: "general.action.reload".localized))
		menu.addItem(NSMenuItemCustomView.new(
			title: "menu.advanced.reload_pock".localized,
			target: self,
			selector: #selector(selectAdvancedSectionItem(_:)),
			keyEquivalent: "r"
		))
		menu.addItem(NSMenuItemCustomView.new(
			title: "menu.advanced.relaunch_pock".localized,
			target: self,
			selector: #selector(selectAdvancedSectionItem(_:)),
			keyEquivalent: "R",
			isAlternate: true
		))
		menu.addItem(NSMenuItemCustomView.new(
			title: "menu.advanced.reload_touchbar".localized,
			target: self,
			selector: #selector(selectAdvancedSectionItem(_:)),
			keyEquivalent: "s"
		))
		menu.addItem(NSMenuItemCustomView.new(
			title: "menu.advanced.relaunch_touchbar".localized,
			target: self,
			selector: #selector(selectAdvancedSectionItem(_:)),
			keyEquivalent: "S",
			isAlternate: true
		))
        menu.addItem(NSMenuHeader.new(title: "menu.developers".localized))
        menu.addItem(NSMenuItemCustomView.new(
            title: "menu.advanced.show_debug_console".localized,
            target: self,
            selector: #selector(selectAdvancedSectionItem(_:)),
            keyEquivalent: "d"
        ))
		let menuItem = NSMenuItem(title: "menu.advanced".localized, action: nil, keyEquivalent: "")
		menuItem.submenu = menu
		menuItem.view = NSMenuItemCustomView(item: menuItem)
		return menuItem
	}()
	
	// MARK: Debug menu
	#if DEBUG
	private lazy var _debugMenuItem: NSMenuItem = {
		let debugMenu = NSMenu(title: "PockDebug")
		debugMenu.addItem(NSMenuHeader.new(title: "Widgets"))
		debugMenu.addItem(withTitle: "Reload Widgets", action: #selector(reloadWidgets), keyEquivalent: "")
		debugMenu.addItem(NSMenuHeader.new(title: "General"))
		debugMenu.addItem(withTitle: "Open On-Board…", action: #selector(openOnBoardController), keyEquivalent: "")
		debugMenu.addItem(withTitle: "Toggle Touch Bar visibility", action: #selector(toggleTouchBarVisibility), keyEquivalent: "")
		debugMenu.addItem(withTitle: "Relaunch TouchPlay", action: #selector(relaunch), keyEquivalent: "")
		let debugMenuItem = NSMenuItem(title: "Debug…", action: nil, keyEquivalent: "")
		debugMenuItem.submenu = debugMenu
		debugMenuItem.view = NSMenuItemCustomView(item: debugMenuItem)
		return debugMenuItem
	}()
	#endif

	// MARK: Main bar menu items
	// swiftlint:disable function_body_length
	private func setupMainBarMenuItems() {
		// MARK: About Pock
		mainBarMenu.addItem(NSMenuHeader.new(title: "menu.general".localized, height: 22))
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "menu.about".localized,
			target: self,
			selector: #selector(openWebsite),
			keyEquivalent: nil
		))
		
		// MARK: Preferences
		preferencesMenuItem = NSMenuBadgeItemView.item(
			title: "menu.preferences".localized,
			target: self,
			selector: #selector(openPreferences),
			keyEquivalent: ","
		)
		mainBarMenu.addItem(preferencesMenuItem)
		
		// MARK: Widgets
		mainBarMenu.addItem(NSMenuHeader.new(title: "menu.widgets".localized))
		manageWidgetsMenuItem = NSMenuBadgeItemView.item(
			title: "menu.widgets.manage-widgets".localized,
			target: self,
			selector: #selector(openWidgetsManager),
			keyEquivalent: "m"
		)
		mainBarMenu.addItem(manageWidgetsMenuItem)
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "menu.widgets.install-widget".localized,
			target: self,
			selector: #selector(openWidgetInstallPanel),
			keyEquivalent: "i"
		))
		
		// MARK: Customize Touch Bar
		mainBarMenu.addItem(NSMenuHeader.new(title: "menu.customization".localized))
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "menu.customization.pock".localized,
			target: self,
			selector: #selector(openCustomizationPalette),
			keyEquivalent: "p"
		))
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "menu.customization.control-strip".localized,
			target: self,
			selector: #selector(openCustomizationPalette),
			keyEquivalent: "c"
		))
		
		// MARK: PockAI
		mainBarMenu.addItem(NSMenuHeader.new(title: "TouchPlay"))
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "Writing Tools for Selected Text  ⌃⌥W",
			target: self,
			selector: #selector(openWritingTools),
			keyEquivalent: nil
		))
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "TouchPlay ↔ App's own Touch Bar  ⌃⌃",
			target: self,
			selector: #selector(toggleAppTouchBar),
			keyEquivalent: nil
		))
		let purrItem = NSMenuItem(title: "Lyrics & Player", action: nil, keyEquivalent: "")
		purrItem.submenu = NSMenu(title: "Lyrics & Player")
		purrItem.submenu?.delegate = self
		purrItem.view = NSMenuItemCustomView(item: purrItem)
		mainBarMenu.addItem(purrItem)
		let subsMenu = NSMenu(title: "Subtitles")
		subsMenu.addItem(withTitle: "Install Browser Extension…", action: #selector(installExtension), keyEquivalent: "").target = self
		subsMenu.addItem(withTitle: "Load Subtitle File…", action: #selector(loadSubtitleFile), keyEquivalent: "").target = self
		subsMenu.addItem(withTitle: "Subtitle Settings…", action: #selector(openSubtitleSettings), keyEquivalent: "").target = self
		let subsItem = NSMenuItem(title: "Subtitles", action: nil, keyEquivalent: "")
		subsItem.submenu = subsMenu
		subsItem.view = NSMenuItemCustomView(item: subsItem)
		mainBarMenu.addItem(subsItem)
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "TouchPlay Settings…",
			target: self,
			selector: #selector(openPockAISettings),
			keyEquivalent: nil
		))

		// MARK: Advanced
		mainBarMenu.addItem(NSMenuHeader.new(title: "menu.advanced".localized))
		mainBarMenu.addItem(advancedMenuItem)

		#if DEBUG
		// MARK: Debug
		mainBarMenu.addItem(NSMenuHeader.new(title: "Debug"))
		mainBarMenu.addItem(_debugMenuItem)
		#endif
		
		// MARK: Quit Pock
		mainBarMenu.addItem(NSMenuHeader.new(title: "menu.goodbye".localized))
		mainBarMenu.addItem(NSMenuItemCustomView.new(
			title: "menu.quit".localized,
			target: NSApp,
			selector: #selector(NSApp.terminate(_:)),
			keyEquivalent: "q"
		))
		
		// MARK: Set indentation level for advanced menu
		if #available(macOS 11, *) {
			return
		}
	}
	// swiftlint:enable function_body_length
	
	// MARK: Update menu items for new versions
	@objc private func updateMenuItemsAfterLatestVersionsFetch() {
		guard let latestVersions = Updater.cachedLatestReleases else {
			return
		}
		var coreBadge: Int = 0
        if latestVersions.core.name.isGreatherThan(Updater.fullAppVersion) {
			coreBadge = 1
		}
		var widgetsToUpdate: Int = 0
		for widget in WidgetsLoader.installedWidgets {
            let newVersion = Updater.newVersion(for: widget)
            if newVersion.version != nil || newVersion.error != nil {
				widgetsToUpdate += 1
			}
		}
		async { [weak self, coreBadge, widgetsToUpdate] in
			guard let self = self else {
				return
			}
			self.preferencesMenuItem.setBadge(coreBadge > 0 ? "\(coreBadge)" : nil)
			self.manageWidgetsMenuItem.setBadge(widgetsToUpdate > 0 ? "\(widgetsToUpdate)" : nil)
			if coreBadge + widgetsToUpdate > 0 {
				let base = self.mainBarItem.button
				let badge = NSView(frame: .zero)
				badge.wantsLayer = true
				badge.layer?.backgroundColor = NSColor.systemRed.cgColor
				badge.layer?.cornerRadius = 2
				base?.addSubview(badge)
				badge.height(4)
				badge.width(4)
				badge.rightToSuperview(offset: -3)
				badge.bottomToSuperview(offset: -4)
			} else {
				self.mainBarItem.button?.subviews.forEach({ $0.removeFromSuperview() })
			}
		}
	}

	// MARK: PockAI actions
	@objc private func openWritingTools() {
		Task { @MainActor in await WritingToolsController.shared.show() }
	}
	@objc private func openPockAISettings() { PockAISettings.open() }
	@objc private func openSubtitleSettings() { PockAISettings.open(tab: .subtitles) }
	@objc private func installExtension() { PockAISettings.installBrowserExtension() }
	@objc private func loadSubtitleFile() { PockAISettings.chooseSubtitleFile() }

	// MARK: Open website
	@objc private func openWebsite() {
		let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0"
		let credits = NSMutableAttributedString(
			string: "Made by Shaheer Muzaffar\n",
			attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
		)
		credits.append(NSAttributedString(
			string: "Widgets, lyrics, games and Control Center for your Touch Bar.\nIncludes open-source code from Pock (MIT licence).",
			attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
		))
		let centred = NSMutableParagraphStyle(); centred.alignment = .center
		credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
		NSApp.activate(ignoringOtherApps: true)
		NSApp.orderFrontStandardAboutPanel(options: [
			.applicationName: "TouchPlay",
			.applicationVersion: version,
			.version: "",
			.credits: credits,
			NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Shaheer Muzaffar"
		])
	}
	
	// MARK: Open preferences
	@objc private func openPreferences() {
		AppController.shared.openController(PreferencesViewController())
	}
	
	// MARK: Open widgets manager
	@objc private func openWidgetsManager() {
		AppController.shared.openController(WidgetsManagerViewController())
	}
	
	// MARK: Open widget install panel
	@objc private func openWidgetInstallPanel() {
		let controller = WidgetsManagerViewController()
		AppController.shared.openController(controller)
		controller.presentWidgetInstallPanel(withInitialState: .dragdrop)
	}
	
	// MARK: Open customization menu
	@objc private func openCustomizationPalette(_ sender: NSMenuItem) {
		switch sender.keyEquivalent {
		case "p":
			AppController.shared.openPockCustomizationPalette()
		case "c":
			AppController.shared.openControlStripCustomizationPalette()
		default:
			return
		}
	}
	
	// MARK: Select advanced section item
	@objc private func selectAdvancedSectionItem(_ sender: NSMenuItem) {
        switch sender.keyEquivalent {
        case "w":
			AppController.shared.reInstallDefaultWidgets()
        case "f":
            NSWorkspace.shared.open(kWidgetsPathURL)
        case "r":
            AppController.shared.reload(shouldFetchLatestVersions: true)
        case "R":
            AppController.shared.relaunch()
        case "s":
            TouchBarHelper.reloadTouchBarAgent()
        case "S":
            TouchBarHelper.reloadTouchBarServer { _ in
                NSApp.activate(ignoringOtherApps: true)
            }
        case "d":
            AppController.shared.showDebugConsole()
        default:
            return
        }
	}
	
	// MARK: Open On-Board window
	@objc private func openOnBoardController() {
		AppController.shared.openController(OnBoardViewController())
	}
    
    @objc private func toggleAppTouchBar() {
        AppController.shared.toggleVisibility()
    }

    // MARK: Show debug console
    @objc private func showDebugConsole() {
        AppController.shared.showDebugConsole()
    }

}

#if DEBUG
private extension AppDelegate {
	// MARK: Toggle Touch Bar visibility
	@objc private func toggleTouchBarVisibility() {
		AppController.shared.toggleVisibility()
	}
	// MARK: Reload Widgets
	@objc private func reloadWidgets() {
		AppController.shared.reloadWidgets {}
	}
	// MARK: Relaunch Pock
	@objc private func relaunch() {
		AppController.shared.relaunch()
	}
}
#endif


// MARK: Lyrics & Player submenu is rebuilt each time it opens (shows current choices)
extension AppDelegate: NSMenuDelegate {
	func menuNeedsUpdate(_ menu: NSMenu) {
		guard menu.title == "Lyrics & Player" else { return }
		menu.removeAllItems()
		for item in PurrPlayer.shared.makeSettingsMenu().items {
			item.menu?.removeItem(item)
			menu.addItem(item)
		}
	}
}
