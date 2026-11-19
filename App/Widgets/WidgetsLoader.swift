//
//  WidgetsLoader.swift
//  PockAI (based on Pock by Pierluigi Galdi)
//
//  Loads the widgets shipped inside the app (Contents/PlugIns) plus any third-party
//  widgets the user installed in ~/Library/Application Support/PockAI/Widgets.
//  A broken or duplicate widget is skipped instead of taking the whole app down.
//

import AppKit
import Foundation
import PockKit

// MARK: Notifications

extension NSNotification.Name {
	static let didLoadWidgets = NSNotification.Name("didLoadWidgets")
}

// MARK: Helpers

private var kApplicationSupportPockFolder: String {
	let prefix: String
	if let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path {
		prefix = path
	} else {
		prefix = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support"
	}
	return prefix + "/PockAI"
}
internal let kWidgetsPath: String = kApplicationSupportPockFolder + "/Widgets"
internal let kWidgetsPathURL: URL = URL(fileURLWithPath: kWidgetsPath)
internal let kWidgetsTempPathURL: URL = URL(fileURLWithPath: kWidgetsPath + "/tmp")

// MARK: Loader

internal final class WidgetsLoader {

	/// Typealias
	typealias WidgetsLoaderHandler = ([PKWidgetInfo]) -> Void

	/// File manager
	private let fileManager = FileManager.default

	/// Data
	public static var loadedWidgets: [PKWidgetInfo] {
		return installedWidgets.filter({ $0.loaded == true })
	}

	/// List of installed widgets (loaded or not)
	public static var installedWidgets: [PKWidgetInfo] = []

	// MARK: Built-in widgets

	private static let disabledBuiltInsKey = "disabledBuiltInWidgets"

	/// Widgets shipped inside the app bundle.
	static var builtInWidgetURLs: [URL] {
		guard let plugins = Bundle.main.builtInPlugInsURL,
			  let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else {
			return []
		}
		return items.filter { $0.pathExtension == "pock" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
	}

	static func isBuiltIn(_ widget: PKWidgetInfo) -> Bool {
		guard let plugins = Bundle.main.builtInPlugInsURL?.standardizedFileURL.path else { return false }
		return widget.path.standardizedFileURL.path.hasPrefix(plugins)
	}

	private static var disabledBuiltIns: Set<String> {
		get { Set(UserDefaults.standard.stringArray(forKey: disabledBuiltInsKey) ?? []) }
		set { UserDefaults.standard.set(Array(newValue), forKey: disabledBuiltInsKey) }
	}

	static func setBuiltIn(_ identifier: String, enabled: Bool) {
		var set = disabledBuiltIns
		if enabled { set.remove(identifier) } else { set.insert(identifier) }
		disabledBuiltIns = set
	}

	static func enableAllBuiltIns() {
		disabledBuiltIns = []
	}

	init() {
		/// Create support folders, if needed
		guard createSupportFoldersIfNeeded() else {
			Roger.error("Can't create support folders at \(kWidgetsPath)")
			return
		}
	}

	/// Create support folders, if needed
	private func createSupportFoldersIfNeeded() -> Bool {
		return fileManager.createFolderIfNeeded(at: kApplicationSupportPockFolder) && fileManager.createFolderIfNeeded(at: kWidgetsPath)
	}

	/// Bundle identifier from Info.plist, read WITHOUT loading the widget's code.
	private func bundleIdentifier(at url: URL) -> String? {
		let plist = url.appendingPathComponent("Contents/Info.plist")
		return (NSDictionary(contentsOf: plist)?["CFBundleIdentifier"] as? String)
	}

	/// Load installed widgets
	internal func loadInstalledWidgets(_ completion: @escaping WidgetsLoaderHandler) {
		WidgetsLoader.installedWidgets.removeAll()
		var widgets: [PKWidgetInfo] = []
		var seen = Set<String>()
		let disabled = WidgetsLoader.disabledBuiltIns
		// 1. Built-in widgets (always win over a same-ID copy in the user folder).
		for url in WidgetsLoader.builtInWidgetURLs {
			guard let id = bundleIdentifier(at: url)?.lowercased(), !seen.contains(id) else { continue }
			seen.insert(id)
			if disabled.contains(where: { $0.lowercased() == id }) {
				if let info = try? PKWidgetInfo(unloadableWidgetAtPath: url) {
					WidgetsLoader.installedWidgets.append(info)
				}
				continue
			}
			if let widget = loadWidgetAtURL(url) { widgets.append(widget) }
		}
		// 2. User-installed widgets.
		let userURLs = fileManager.filesInFolder(kWidgetsPath, filter: {
			$0.contains(".pock") && !$0.contains("disabled") && !$0.contains("/")
		})
		for url in userURLs {
			guard let id = bundleIdentifier(at: url)?.lowercased() else { continue }
			guard !seen.contains(id) else {
				Roger.info("Skipping `\(url.lastPathComponent)`: a built-in widget with the same identifier is already loaded.")
				continue
			}
			seen.insert(id)
			if let widget = loadWidgetAtURL(url) { widgets.append(widget) }
		}
		completion(widgets)
		NotificationCenter.default.post(name: .didLoadWidgets, object: nil)
	}

	/// Load single widget
	private func loadWidgetAtURL(_ url: URL) -> PKWidgetInfo? {
		do {
			let info = try PKWidgetInfo(path: url)
			if !WidgetsLoader.installedWidgets.contains(info) {
				WidgetsLoader.installedWidgets.append(info)
			}
			return info
		} catch let error1 {
			do {
				let info = try PKWidgetInfo(unloadableWidgetAtPath: url)
				if !WidgetsLoader.installedWidgets.contains(info) {
					WidgetsLoader.installedWidgets.append(info)
				}
				return info
			} catch let error2 {
				Roger.error(error2.localizedDescription)
			}
			Roger.error(error1.localizedDescription)
			return nil
		}
	}

}
