//
//  WidgetsManagerViewController.swift
//  Pock
//
//  Created by Pierluigi Galdi on 30/04/21.
//

import Cocoa
import PockKit
import TinyConstraints

class WidgetsManagerViewController: NSViewController {
	
	// MARK: Cell Identifiers
	
	private enum CellIdentifiers {
		static let widgetCell: NSUserInterfaceItemIdentifier = NSUserInterfaceItemIdentifier("widgetCellIdentifier")
	}
	
    // MARK: UI Elements
	///
	/// Common UI elements
	@IBOutlet private weak var tableView: NSTableView!
	/// Selected widget's UI elements
	@IBOutlet private weak var widgetNameLabel: NSTextField!
	@IBOutlet private weak var widgetAuthorLabel: NSTextField!
	@IBOutlet private weak var widgetVersionLabel: NSTextField!
	@IBOutlet private weak var widgetInstallButton: NSButton!
	@IBOutlet private weak var widgetUpdateButton: NSButton!
	@IBOutlet private weak var widgetUninstallButton: NSButton!
	@IBOutlet private weak var widgetUpdateStatusLabel: NSTextField!
	@IBOutlet private weak var widgetPreferencesContainer: NSView!
	@IBOutlet private weak var widgetPreferencesStatusLabel: NSTextField!
    @IBOutlet private weak var widgetPreferencesHorizontalLine: NSView!
    @IBOutlet private weak var widgetPreferencesResetButton: NSButton!
	
	@IBOutlet private weak var checkForWidgetsUpdateButton: NSButton!
	
	// MARK: Data
	
	private var widgets: [PKWidgetInfo] {
		return WidgetsLoader.installedWidgets.sorted(by: { $0.name < $1.name })
	}
	private var selectedWidget: PKWidgetInfo? {
		didSet {
			if let widget = selectedWidget {
				selectedWidgetNewVersion = Updater.newVersion(for: widget)
			} else {
				selectedWidgetNewVersion = nil
			}
			updateUIElementsForSelectedWidget()
			updatePreferencesContainerForSelectedPreferences()
		}
	}
	private var selectedPreferences: PKWidgetPreference?
	private var preferencesScrollView: NSScrollView?
	private var preferencesHeightConstraint: NSLayoutConstraint?
	private var selectedWidgetNewVersion: Updater.WidgetVersion?
	
	/// Set of disabled widget's `bundleIdentifier` to avoid user selection
	private var disabledWidgets: Set<String> = []
	
	// MARK: Overrides
	
	override var title: String? {
		get {
			return "widgets-manager.list.title".localized
		}
		set {
			view.window?.title = newValue ?? ""
		}
	}
	
	override func viewDidLoad() {
		super.viewDidLoad()
		self.tableView.register(NSNib(nibNamed: "PKWidgetCellView", bundle: .main), forIdentifier: CellIdentifiers.widgetCell)
		self.configureUIElements()
		self.selectedWidget = widgets.first
		if AppController.shared.isVisible == false {
			AppController.shared.reload(shouldFetchLatestVersions: false)
		}
		NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .didLoadWidgets, object: nil)
	}
	
	override func viewWillAppear() {
		super.viewWillAppear()
		NSApp.activate(ignoringOtherApps: true)
	}
	
	override func viewWillDisappear() {
		super.viewWillDisappear()
		NSApp.deactivate()
	}
	
	private func configureUIElements() {
        widgetUpdateButton.title = "general.action.update".localized
        widgetUninstallButton.title = "general.action.remove".localized
		checkForWidgetsUpdateButton.title = "general.action.check-for-updates".localized
		widgetInstallButton.title = "menu.widgets.install-widget".localized
        widgetPreferencesResetButton.title = "widgets-manager.list.reset-preferences".localized
	}
	
	deinit {
		NotificationCenter.default.removeObserver(self)
		selectedWidget = nil
		Roger.debug("[WidgetsManager][List] - deinit")
	}
	
}

// MARK: Methods

extension WidgetsManagerViewController {
	
	@objc private func reload() {
		async { [weak self] in
            if let selectedIndex = self?.tableView.selectedRowIndexes {
                self?.tableView.reloadData()
                self?.tableView.selectRowIndexes(selectedIndex, byExtendingSelection: false)
            } else {
                self?.tableView.reloadData()
            }
		}
	}
	
	private func updatePreferredContentSize() {
		let frame = widgetPreferencesContainer.convert(widgetPreferencesContainer.visibleRect, to: view)
		self.preferredContentSize = NSSize(
			width: frame.origin.x + frame.size.width,
			height: frame.origin.y + frame.size.height
		)
		self.view.layout()
	}
	
	private func updateUIElementsForSelectedWidget() {
		guard let widget = selectedWidget else {
			widgetNameLabel.stringValue = "widgets-manager.list.select-widget".localized
			widgetAuthorLabel.stringValue = "--"
			widgetVersionLabel.stringValue = "--"
			widgetUninstallButton.isEnabled = false
			widgetUpdateButton.isEnabled = false
			widgetUpdateButton.isHighlighted = false
			widgetUpdateStatusLabel.isHidden = true
			return
		}
		widgetNameLabel.stringValue = widget.name
		widgetAuthorLabel.stringValue = widget.author
		widgetVersionLabel.stringValue = widget.fullVersion
		widgetUninstallButton.isEnabled = true
		widgetUpdateButton.isEnabled = selectedWidgetNewVersion?.version != nil
		widgetUpdateButton.isHighlighted = widgetUpdateButton.isEnabled
		widgetUpdateStatusLabel.isHidden = selectedWidgetNewVersion?.error == nil
		widgetUpdateStatusLabel.stringValue = selectedWidgetNewVersion?.error?.description ?? "error.unknown".localized
	}
	
	private func updatePreferencesContainerForSelectedPreferences() {
		guard let widget = selectedWidget, let clss = widget.preferencesClass as? PKWidgetPreference.Type else {
			unloadPreferencesContainerWithTitle("widgets-manager.list.no-preferences".localized)
			selectedPreferences = nil
			return
		}
		if disabledWidgets.contains(where: { $0 == widget.bundleIdentifier }) {
			unloadPreferencesContainerWithTitle("widgets-manager.list.did-update".localized)
		} else {
			unloadPreferencesContainerWithTitle("widgets-manager.loading-preferences".localized)
			selectedPreferences = clss.init(nibName: clss.nibName, bundle: Bundle(for: clss))
			loadPreferencesContainerForSelectedPreferences()
		}
	}
	
	private func loadPreferencesContainerForSelectedPreferences() {
		guard let preferences = selectedPreferences else {
			return
		}
		widgetPreferencesStatusLabel.stringValue = ""
		widgetPreferencesStatusLabel.isHidden = true
		addChild(preferences)
		let pane = preferences.view
		// The page's natural height (SwiftUI pages report it; nib pages have a fixed frame).
		let natural = max(pane.fittingSize.height, pane.frame.height, 60)
		// Top-aligned in a scroll view: a tall page scrolls instead of stretching the window off-screen.
		let scroll = NSScrollView()
		scroll.drawsBackground = false
		scroll.borderType = .noBorder
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.horizontalScrollElasticity = .none
		let document = FlippedView()
		document.translatesAutoresizingMaskIntoConstraints = false
		pane.translatesAutoresizingMaskIntoConstraints = false
		document.addSubview(pane)
		scroll.documentView = document
		widgetPreferencesContainer.addSubview(scroll)
		scroll.edgesToSuperview()
		NSLayoutConstraint.activate([
			document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
			document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
			document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
			pane.topAnchor.constraint(equalTo: document.topAnchor),
			pane.leadingAnchor.constraint(equalTo: document.leadingAnchor),
			pane.trailingAnchor.constraint(equalTo: document.trailingAnchor),
			pane.bottomAnchor.constraint(equalTo: document.bottomAnchor),
			pane.heightAnchor.constraint(equalToConstant: natural)
		])
		preferencesScrollView = scroll
		setPreferencesHeight(natural)
        widgetPreferencesHorizontalLine.isHidden = false
        widgetPreferencesResetButton.isHidden = false
		async { [weak self] in
			self?.fitWindowToContent()
		}
	}

	/// Automation / testing: select a widget by its name.
	internal func select(widgetNamed name: String) {
		guard let index = widgets.firstIndex(where: { $0.name == name }) else { return }
		tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
		tableView.scrollRowToVisible(index)
	}

	// MARK: Window sizing (grows and shrinks with each widget's settings)

	/// Space the window needs besides the settings area (title bar, header, reset button, margins).
	private var chromeHeight: CGFloat { 220 }

	private func setPreferencesHeight(_ natural: CGFloat) {
		let screen = view.window?.screen ?? NSScreen.main
		let available = (screen?.visibleFrame.height ?? 800) - chromeHeight
		let height = min(max(natural, 120), max(200, available))
		// The nib asks for at least 270 pt; let short pages be short.
		for c in widgetPreferencesContainer.constraints where c.firstAttribute == .height && c.relation == .greaterThanOrEqual {
			c.constant = 120
		}
		if let c = preferencesHeightConstraint {
			c.constant = height
		} else {
			let c = widgetPreferencesContainer.heightAnchor.constraint(equalToConstant: height)
			c.priority = .required
			c.isActive = true
			preferencesHeightConstraint = c
		}
	}

	/// Resize the window to exactly fit, keeping its top edge where it is and staying on screen.
	private func fitWindowToContent() {
		guard let window = view.window else { return }
		view.layoutSubtreeIfNeeded()
		let fitting = view.fittingSize
		guard fitting.height > 100 else { return }
		var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: max(fitting.width, view.frame.width), height: fitting.height)))
		let top = window.frame.maxY
		frame.origin.x = window.frame.origin.x
		frame.origin.y = top - frame.height
		if let visible = window.screen?.visibleFrame {
			if frame.minY < visible.minY { frame.origin.y = visible.minY }
			if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
		}
		window.setFrame(frame, display: true, animate: window.isVisible)
	}
	
	private func unloadPreferencesContainerWithTitle(_ title: String) {
        widgetPreferencesHorizontalLine.isHidden = true
        widgetPreferencesResetButton.isHidden = true
        preferencesScrollView?.removeFromSuperview()
        preferencesScrollView = nil
        selectedPreferences?.view.removeFromSuperview()
		selectedPreferences?.removeFromParent()
		selectedPreferences = nil
		widgetPreferencesStatusLabel.stringValue = title
		widgetPreferencesStatusLabel.isHidden = false
		setPreferencesHeight(140)
		async { [weak self] in self?.fitWindowToContent() }
	}
	
	internal func presentWidgetInstallPanel(withInitialState state: WidgetsInstaller.State) {
		let controller = WidgetsInstallViewController()
		controller.state = state
		presentAsSheet(controller)
	}
	
	@IBAction internal func presentWidgetInstallerPanelFrom(_ button: NSButton) {
		let state: WidgetsInstaller.State
		switch button {
		case widgetInstallButton:
			state = .dragdrop
		case widgetUpdateButton:
			guard let widget = selectedWidget, let newVersion = selectedWidgetNewVersion?.version else {
				return
			}
			state = .update(widget: widget, version: newVersion)
		case widgetUninstallButton:
			guard let widget = selectedWidget else {
				return
			}
			state = .remove(widget: widget)
		default:
			return
		}
		presentWidgetInstallPanel(withInitialState: state)
	}
	
	@IBAction private func checkForWidgetsUpdates(_ sender: Any?) {
		checkForWidgetsUpdateButton.isEnabled = false
		checkForWidgetsUpdateButton.title = "general.action.checking".localized
		AppController.shared.fetchLatestVersions { [weak self] in
			dsleep(1)
			self?.checkForWidgetsUpdateButton.isEnabled = true
			self?.checkForWidgetsUpdateButton.title = "general.action.check-for-updates".localized
			self?.reload()
		}
	}
    
    @IBAction private func resetWidgetPreferences(_ sender: Any?) {
        selectedPreferences?.reset?()
        unloadPreferencesContainerWithTitle("Resetting preferences to default values…")
        async(after: 1.325) { [weak self] in
            self?.updatePreferencesContainerForSelectedPreferences()
        }
    }
	
}

// MARK: Table - Data Source

extension WidgetsManagerViewController: NSTableViewDataSource {
	
	func numberOfRows(in tableView: NSTableView) -> Int {
		return widgets.count
	}
	
	func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		return 44
	}
	
	func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
		return 220
	}
	
}

// MARK: Table - Delegate

extension WidgetsManagerViewController: NSTableViewDelegate {
	
	/// View for cell in row
	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		/// Check for cell
		guard row < widgets.count, let cell = tableView.makeView(withIdentifier: CellIdentifiers.widgetCell, owner: nil) as? PKWidgetCellView else {
			return nil
		}
		/// Get item
		let widget = widgets[row]
		let disabled = disabledWidgets.contains(where: { $0 == widget.bundleIdentifier })
		/// Setup cell
		cell.status.image = NSImage(named: widget.loaded ? NSImage.statusAvailableName : NSImage.statusUnavailableName)
		cell.name.stringValue = widget.name
		cell.name.alphaValue  = disabled ? 0.475 : 1
        let newVersion = Updater.newVersion(for: widget)
        cell.badge.isHidden = disabled || newVersion.version == nil && newVersion.error == nil
		/// Return
		return cell
	}
	
	func tableViewSelectionDidChange(_ notification: Notification) {
		self.selectedWidget = tableView.selectedRow > -1 ? widgets[tableView.selectedRow] : nil
	}
	
}


/// Top-to-bottom coordinates so a settings page sits at the top of its scroll view.
private final class FlippedView: NSView {
	override var isFlipped: Bool { true }
}
