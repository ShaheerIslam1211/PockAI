import AppKit
import SwiftUI

/// Settings for showing each app's own Touch Bar (see AppTouchBarSwitcher in the app).
public enum AppControlsSettings {
	public static let buttonKey = "pockai.apps.button"
	public static let followKey = "pockai.apps.follow"
	public static let autoKey = "pockai.apps.auto"
	public static let choiceKey = "pockai.apps.choice"

	/// Apps known for good Touch Bar controls: they start with their own controls.
	public static let defaultAutomaticApps = [
		"com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
		"com.apple.Music", "com.apple.TV", "com.apple.Photos", "com.apple.QuickTimePlayerX", "com.apple.Preview",
		"com.apple.FinalCut", "com.apple.logic10", "com.apple.garageband10", "com.apple.iMovieApp",
		"com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
		"com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook",
		"com.adobe.Photoshop", "com.adobe.illustrator", "com.adobe.LightroomClassicCC7", "com.adobe.PremierePro",
		"com.pixelmatorteam.pixelmator.x", "com.apple.dt.Xcode", "com.apple.FaceTime", "com.apple.Maps"
	]

	public static var showsAppButton: Bool { UserDefaults.standard.object(forKey: buttonKey) as? Bool ?? true }
	public static var followsApps: Bool { UserDefaults.standard.object(forKey: followKey) as? Bool ?? true }
	public static var automaticApps: [String] {
		get { UserDefaults.standard.stringArray(forKey: autoKey) ?? defaultAutomaticApps }
		set {
			UserDefaults.standard.set(newValue, forKey: autoKey)
			NotificationCenter.default.post(name: PockAIWidgetSettingsDidChange, object: autoKey)
		}
	}
	public static var choices: [String: String] {
		get { UserDefaults.standard.dictionary(forKey: choiceKey) as? [String: String] ?? [:] }
		set { UserDefaults.standard.set(newValue, forKey: choiceKey) }
	}

	static func displayName(_ bundleID: String) -> String {
		guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
		return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
	}
	static func isInstalled(_ bundleID: String) -> Bool {
		NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
	}
}

/// "App controls" section for PockAI Settings → Touch Bar.
struct AppControlsSection: View {
	@State private var apps = AppControlsSettings.automaticApps
	@State private var choiceCount = AppControlsSettings.choices.count

	var body: some View {
		Section("Apps' own Touch Bar (Safari, Chrome, Music, Photoshop, Word…)") {
			Toggle("Show the app you're in as the first button — tap it for that app's own controls",
				   isOn: setting(AppControlsSettings.buttonKey, true))
			Toggle("Switch automatically when you change apps (your choice is remembered per app)",
				   isOn: setting(AppControlsSettings.followKey, true))
			Text("The PockAI button in the Control Strip brings PockAI back (tap again for the app's controls).")
				.font(.caption).foregroundStyle(.secondary)
			DisclosureGroup("Apps that start with their own controls (\(apps.filter(AppControlsSettings.isInstalled).count) installed)") {
				ForEach(apps.filter(AppControlsSettings.isInstalled), id: \.self) { id in
					HStack {
						Text(AppControlsSettings.displayName(id))
						Spacer()
						Button("Remove") { save(apps.filter { $0 != id }) }
					}
				}
				HStack {
					Button("Add app…") { addApp() }
					Button("Restore list") { save(AppControlsSettings.defaultAutomaticApps) }
				}
			}
			HStack {
				Button("Forget my per-app choices") {
					AppControlsSettings.choices = [:]
					choiceCount = 0
					NotificationCenter.default.post(name: PockAIWidgetSettingsDidChange, object: AppControlsSettings.choiceKey)
				}
				.disabled(choiceCount == 0)
				Text(choiceCount == 0 ? "No per-app choices yet" : "\(choiceCount) app(s) remembered")
					.font(.caption).foregroundStyle(.secondary)
			}
		}
		.onAppear { choiceCount = AppControlsSettings.choices.count }
	}

	private func save(_ list: [String]) {
		apps = list
		AppControlsSettings.automaticApps = list
	}

	private func addApp() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [.applicationBundle]
		panel.directoryURL = URL(fileURLWithPath: "/Applications")
		panel.allowsMultipleSelection = true
		guard panel.runModal() == .OK else { return }
		let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
		save(apps + ids.filter { !apps.contains($0) })
	}
}
