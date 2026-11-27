import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// PockAI's settings window: AI, Lyrics, Subtitles, Touch Bar size and permissions.
public enum PockAISettings {

	public enum Tab: String { case ai, lyrics, subtitles, touchBar }

	private static var window: NSWindow?

	public static func open(tab: Tab = .ai) {
		let model = SettingsModel.shared
		model.tab = tab
		model.refresh()
		if window == nil {
			let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
			w.title = "TouchPlay Settings"
			w.styleMask = [.titled, .closable, .miniaturizable]
			w.isReleasedWhenClosed = false
			w.center()
			window = w
		}
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
	}

	/// Folder of the browser extension inside the app bundle.
	public static var extensionFolder: URL? {
		Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension")
	}

	/// Copies the extension to ~/Documents/PockAI Subtitles Extension (browsers want a stable folder) and reveals it.
	public static func installBrowserExtension() {
		guard let source = extensionFolder else { return }
		let fm = FileManager.default
		let dest = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/PockAI Subtitles Extension")
		try? fm.removeItem(at: dest)
		try? fm.copyItem(at: source, to: dest)
		NSWorkspace.shared.activateFileViewerSelecting([dest])
		let alert = NSAlert()
		alert.messageText = "Install the TouchPlay Subtitles extension"
		alert.informativeText = """
		1. In Chrome / Edge / Brave / Arc open chrome://extensions
		2. Turn on “Developer mode” (top right)
		3. Click “Load unpacked” and choose the folder “PockAI Subtitles Extension” (just opened in Finder, in Documents).

		Then play Netflix, YouTube, Prime Video… with subtitles on.
		"""
		alert.addButton(withTitle: "Copy chrome://extensions")
		alert.addButton(withTitle: "Done")
		NSApp.activate(ignoringOtherApps: true)
		if alert.runModal() == .alertFirstButtonReturn {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString("chrome://extensions", forType: .string)
		}
	}

	/// "Load Subtitle File…" for a movie that's playing in a local player.
	public static func chooseSubtitleFile() {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }
		panel.allowsMultipleSelection = false
		panel.message = "Pick the subtitle file for the video that's playing"
		NSApp.activate(ignoringOtherApps: true)
		if panel.runModal() == .OK, let url = panel.url {
			SubtitleCenter.shared.loadFile(url)
		}
	}
}

final class SettingsModel: ObservableObject {
	static let shared = SettingsModel()

	@Published var tab: PockAISettings.Tab = .ai
	@Published var apiKey = ""
	@Published var keyStatus = ""
	@Published var testing = false
	@Published var accessibility = false
	@Published var screenRecording = false

	func refresh() {
		apiKey = KeyStore.apiKey
		keyStatus = KeyStore.isFromPocketAI ? "Using the key from your PocketAI app." : (KeyStore.hasKey ? "Key saved." : "No key yet.")
		accessibility = AXIsProcessTrusted()
		screenRecording = CGPreflightScreenCaptureAccess()
	}

	func saveKey() {
		guard KeyStore.looksLikeKey(apiKey) else { keyStatus = "That doesn't look like a Gemini key."; return }
		KeyStore.save(apiKey)
		keyStatus = "Key saved."
	}

	func testKey() {
		saveKey()
		testing = true
		Task { @MainActor in
			do {
				_ = try await GeminiClient.shared.run(.fix, text: "this are a test")
				keyStatus = "✓ Gemini answered — Writing Tools are ready."
			} catch {
				keyStatus = error.localizedDescription
			}
			testing = false
		}
	}
}

private struct SettingsView: View {
	@ObservedObject var model: SettingsModel

	var body: some View {
		TabView(selection: $model.tab) {
			AITab(model: model).tabItem { Label("Writing Tools", systemImage: "sparkles") }.tag(PockAISettings.Tab.ai)
			LyricsTab().tabItem { Label("Lyrics", systemImage: "music.note") }.tag(PockAISettings.Tab.lyrics)
			SubtitlesTab(model: model).tabItem { Label("Subtitles", systemImage: "captions.bubble") }.tag(PockAISettings.Tab.subtitles)
			TouchBarTab(model: model).tabItem { Label("Touch Bar", systemImage: "rectangle.and.hand.point.up.left") }.tag(PockAISettings.Tab.touchBar)
		}
		.padding(18)
		.frame(width: 560, height: 470)
	}
}

private struct AITab: View {
	@ObservedObject var model: SettingsModel
	@AppStorage("pockai.ai.onlyOnSelection") private var onlyOnSelection = true
	@AppStorage("pockai.ai.applyDirectly") private var applyDirectly = false

	var body: some View {
		Form {
			Section("Gemini API key (free)") {
				SecureField("Paste your key", text: $model.apiKey)
				HStack {
					Button("Save") { model.saveKey() }
					Button(model.testing ? "Testing…" : "Test") { model.testKey() }.disabled(model.testing)
					Link("Get a free key", destination: URL(string: "https://aistudio.google.com/apikey")!)
				}
				Text(model.keyStatus).font(.caption).foregroundStyle(.secondary)
			}
			Section("Touch Bar") {
				Toggle("Show ✨ only while text is selected", isOn: $onlyOnSelection)
					.onChange(of: onlyOnSelection) { v in SharedSettings.onlyOnSelection = v }
				Toggle("Proofread, Rewrite… replace the text straight away (Undo on the Touch Bar)", isOn: $applyDirectly)
					.onChange(of: applyDirectly) { v in SharedSettings.applyDirectly = v }
				Text("Select text anywhere → tap ✨ on the Touch Bar → pick Proofread, Summary, Key Points… → Replace or Copy. Long-press ✨ for the full panel. Shortcut: ⌃⌥W.")
					.font(.caption).foregroundStyle(.secondary)
			}
			Section("Permission") {
				PermissionRow(title: "Accessibility (read & replace selected text)", granted: model.accessibility) {
					SelectionBridge.requestTrust()
				}
			}
		}
		.groupedForm()
	}
}

private struct LyricsTab: View {
	@AppStorage("pockai.lyrics.width") private var width = 280.0
	@AppStorage("pockai.lyrics.artwork") private var artwork = true
	@AppStorage("pockai.lyrics.nextLine") private var nextLine = true
	@AppStorage("pockai.lyrics.hideIdle") private var hideIdle = true
	@AppStorage("pockai.purr.autoOpen") private var autoOpen = false
	@AppStorage("pockai.lyrics.fullWhenNoRoom") private var fullWhenNoRoom = true

	var body: some View {
		Form {
			Section("Lyrics widget") {
				Slider(value: $width, in: 200...700, step: 10) { Text("Width: \(Int(width)) pt") }
				Toggle("Show album art", isOn: $artwork)
				Toggle("Show the next line underneath", isOn: $nextLine)
				Toggle("Hide when no song is playing (videos leave room for subtitles)", isOn: $hideIdle)
			}
			Section("Full player (Purr)") {
				Toggle("Open the full-bar player automatically when music starts", isOn: $autoOpen)
				Toggle("If the bar is full, open the full player for lyrics", isOn: $fullWhenNoRoom)
				Text("Tap the Lyrics widget to open the full player with lyrics, equaliser and controls. Long-press to hide / show lyrics. Swipe for next / previous song. Themes, translation and script are in the TouchPlay menu → Lyrics & Player.")
					.font(.caption).foregroundStyle(.secondary)
			}
		}
		.groupedForm()
		.onChange(of: width) { _ in post() }
		.onChange(of: artwork) { _ in post() }
		.onChange(of: nextLine) { _ in post() }
		.onChange(of: hideIdle) { _ in post() }
	}

	private func post() { NotificationCenter.default.post(name: LyricsWidgetSettings.didChange, object: nil) }
}

private struct SubtitlesTab: View {
	@ObservedObject var model: SettingsModel
	@AppStorage("pockai.subs.width") private var width = 360.0
	@AppStorage("pockai.subs.hideEmpty") private var hideEmpty = true
	@AppStorage("pockai.subs.bridge") private var bridge = true
	@AppStorage("pockai.subs.local") private var local = true
	@AppStorage("pockai.subs.ocr") private var ocr = false
	@AppStorage("pockai.subs.offset") private var offset = 0.0
	@AppStorage("pockai.subs.autoFull") private var autoFull = true

	var body: some View {
		Form {
			Section("Sources") {
				Toggle("Browser extension (Netflix, YouTube, Prime Video, Disney+, Max, Hulu…)", isOn: $bridge)
				Button("Install Browser Extension…") { PockAISettings.installBrowserExtension() }
				Toggle("Subtitle files next to local movies (IINA, VLC, QuickTime…)", isOn: $local)
				HStack {
					Text("File timing: \(String(format: "%+.1f", offset)) s")
					Stepper("", value: $offset, in: -30...30, step: 0.5).labelsHidden()
					Button("Load Subtitle File…") { PockAISettings.chooseSubtitleFile() }
				}
				Toggle("Read subtitles from the screen (any app, Safari) — uses Screen Recording", isOn: $ocr)
			}
			Section("Widget") {
				Slider(value: $width, in: 240...800, step: 10) { Text("Width: \(Int(width)) pt") }
				Toggle("Hide when there are no subtitles", isOn: $hideEmpty)
				Toggle("If the bar is full, show subtitles full-width automatically", isOn: $autoFull)
				Text("Tap the widget for big full-width subtitles. Long-press to hide them (a small CC button stays — tap it to bring them back).")
					.font(.caption).foregroundStyle(.secondary)
			}
			if ocr {
				Section("Permission") {
					PermissionRow(title: "Screen Recording (read on-screen subtitles)", granted: model.screenRecording) {
						CGRequestScreenCaptureAccess()
					}
				}
			}
		}
		.groupedForm()
		.onChange(of: width) { _ in post() }
		.onChange(of: hideEmpty) { _ in post() }
		.onChange(of: bridge) { _ in post() }
		.onChange(of: local) { _ in post() }
		.onChange(of: ocr) { _ in post() }
		.onChange(of: offset) { _ in post() }
	}

	private func post() { NotificationCenter.default.post(name: SubtitleSettings.didChange, object: nil) }
}

private struct TouchBarTab: View {
	@ObservedObject var model: SettingsModel
	@State private var size = TouchBarMetrics.preferredSize

	var body: some View {
		Form {
			Section("Touch Bar size") {
				Picker("This Mac", selection: $size) {
					ForEach(TouchBarMetrics.Size.allCases, id: \.self) { Text($0.title).tag($0) }
				}
				.onChange(of: size) { v in TouchBarMetrics.preferredSize = v }
				Text("Detected: \(TouchBarMetrics.modelIdentifier) → \(TouchBarMetrics.isSixteenInch ? "16-inch" : "13/15-inch") Touch Bar, \(Int(TouchBarMetrics.fullBarContentWidth())) pt usable. Full-bar screens (player, Writing Tools, subtitles) fill it exactly.")
					.font(.caption).foregroundStyle(.secondary)
			}
			Section("Typing suggestions") {
				Toggle("Show typing suggestions on TouchPlay's bar in every app (Notes, Claude, Word, Chrome…)",
					   isOn: setting("pockai.typing", true))
				Text("Words to finish, fix or come next appear over the widgets while you type; tap one to type it. Widgets come back when you stop typing, click, or press Esc or Return. Never shown in password fields.")
					.font(.caption).foregroundStyle(.secondary)
			}
			AppControlsSection()
			Section("Permissions") {
				PermissionRow(title: "Accessibility", granted: model.accessibility) { SelectionBridge.requestTrust() }
				PermissionRow(title: "Screen Recording (optional)", granted: model.screenRecording) { CGRequestScreenCaptureAccess() }
				Button("Re-check") { model.refresh() }
			}
		}
		.groupedForm()
	}
}

private struct PermissionRow: View {
	let title: String
	let granted: Bool
	let action: () -> Void
	var body: some View {
		HStack {
			Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
				.foregroundStyle(granted ? .green : .orange)
			Text(title)
			Spacer()
			if !granted { Button("Allow…", action: action) }
		}
	}
}


extension View {
	/// Grouped form style where available (macOS 13+); plain form on older systems.
	@ViewBuilder func groupedForm() -> some View {
		if #available(macOS 13.0, *) { self.formStyle(.grouped) } else { self.padding(.horizontal, 8) }
	}
}
