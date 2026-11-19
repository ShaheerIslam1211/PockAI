import AppKit
import SwiftUI
import PockKit

// MARK: - Settings pages for the PockAI widgets, shown in Pock's Widgets Manager
//
// Each widget's Info.plist names one of these in `PKWidgetPreferenceClass` (e.g. "PockAIKit.LyricsPreferencePane").
// Pock instantiates it with init(nibName:bundle:); the view is SwiftUI, built in loadView (no nib).

/// Posted with the changed key as `object` whenever a widget setting changes, so widgets update live.
public let PockAIWidgetSettingsDidChange = Notification.Name("pockai.widgetSettingsChanged")

open class PockAIPreferencePane: NSViewController, PKWidgetPreference {

	public class var nibName: NSNib.Name { NSNib.Name("") }

	/// Keys this pane owns (removed on "Reset preferences to default values").
	open var keys: [String] { [] }

	open func makeContent() -> AnyView { AnyView(EmptyView()) }

	open override func loadView() {
		let host = NSHostingView(rootView: makeContent().frame(width: 560).padding(.vertical, 6))
		host.frame = NSRect(x: 0, y: 0, width: 580, height: max(120, host.fittingSize.height))
		view = host
		preferredContentSize = host.frame.size
	}

	@objc open func reset() {
		keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
		NotificationCenter.default.post(name: PockAIWidgetSettingsDidChange, object: nil)
		NotificationCenter.default.post(name: LyricsWidgetSettings.didChange, object: nil)
		NotificationCenter.default.post(name: SubtitleSettings.didChange, object: nil)
		NotificationCenter.default.post(name: SharedSettings.didChange, object: nil)
		// Rebuild the page with the default values.
		let fresh = NSHostingView(rootView: makeContent().frame(width: 560).padding(.vertical, 6))
		fresh.frame = view.frame
		fresh.autoresizingMask = view.autoresizingMask
		if let superview = view.superview {
			superview.replaceSubview(view, with: fresh)
		}
		view = fresh
	}
}

// MARK: Shared bits

/// A UserDefaults-backed binding that announces the change to the widgets.
func setting<T>(_ key: String, _ fallback: T, notify name: Notification.Name = PockAIWidgetSettingsDidChange) -> Binding<T> {
	Binding(
		get: { UserDefaults.standard.object(forKey: key) as? T ?? fallback },
		set: {
			UserDefaults.standard.set($0, forKey: key)
			NotificationCenter.default.post(name: name, object: key)
		}
	)
}

private struct Section_<Content: View>: View {
	let title: String
	@ViewBuilder let content: Content
	init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
			content
		}
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
	}
}

private struct Hint: View {
	let text: String
	init(_ text: String) { self.text = text }
	var body: some View { Text(text).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct WidthSlider: View {
	let title: String
	let binding: Binding<Double>
	let range: ClosedRange<Double>
	var body: some View {
		HStack {
			Text(title)
			Slider(value: binding, in: range, step: 10)
			Text("\(Int(binding.wrappedValue)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
		}
	}
}

private struct PermissionLine: View {
	let title: String
	let granted: () -> Bool
	let ask: () -> Void
	@State private var ok = false
	var body: some View {
		HStack {
			Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundColor(ok ? .green : .orange)
			Text(title)
			Spacer()
			if !ok { Button("Allow…") { ask(); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ok = granted() } } }
		}
		.onAppear { ok = granted() }
	}
}

// MARK: - Lyrics (Purr)

public final class LyricsPreferencePane: PockAIPreferencePane {
	public override var keys: [String] {
		["pockai.lyrics.width", "pockai.lyrics.artwork", "pockai.lyrics.nextLine", "pockai.lyrics.hideIdle", "pockai.lyrics.on",
		 "pockai.lyrics.fullWhenNoRoom", "pockai.purr.autoOpen", "theme", "lyricsScript", "translateTo", "batterySaver",
		 "nightMode", "hideWhenPaused", "keepAwake", "lyricOffsets"]
	}
	public override func makeContent() -> AnyView { AnyView(LyricsPaneView()) }
}

private struct LyricsPaneView: View {
	private let n = LyricsWidgetSettings.didChange
	@State private var theme = Theme.current
	@State private var script = LyricsScript.current
	@State private var translate = TranslateTarget.current
	@State private var saver = BatterySaver.current
	@State private var night = NightMode.current
	@State private var hide = HideWhenPaused.current
	@State private var awake = KeepAwake.current

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Section_("On the Pock bar") {
				Toggle("Show lyrics (off: show the song title instead)", isOn: setting("pockai.lyrics.on", true, notify: n))
				WidthSlider(title: "Width", binding: setting("pockai.lyrics.width", 280.0, notify: n), range: 160...700)
				Toggle("Album art", isOn: setting("pockai.lyrics.artwork", true, notify: n))
				Toggle("Next line underneath", isOn: setting("pockai.lyrics.nextLine", true, notify: n))
				Toggle("Shrink to a ♪ button for videos, hide when nothing plays", isOn: setting("pockai.lyrics.hideIdle", true, notify: n))
				Hint("Tap: full player · Long-press: lyrics on/off · Swipe: next / previous song")
			}
			Section_("Full player") {
				Toggle("Open automatically when music starts", isOn: setting("pockai.purr.autoOpen", false, notify: n))
				Toggle("Open for lyrics when the bar has no room", isOn: setting("pockai.lyrics.fullWhenNoRoom", true, notify: n))
				Picker("Theme", selection: $theme) { ForEach(Theme.allCases, id: \.self) { Text($0.title).tag($0) } }
					.onChange(of: theme) { PurrPlayer.shared.theme = $0 }
				Picker("Night mode", selection: $night) { ForEach(NightMode.allCases, id: \.self) { Text($0.title).tag($0) } }
					.onChange(of: night) { PurrPlayer.shared.nightMode = $0 }
				Picker("Hide player when paused", selection: $hide) { ForEach(HideWhenPaused.allCases, id: \.self) { Text($0.title).tag($0) } }
					.onChange(of: hide) { PurrPlayer.shared.hideWhenPaused = $0 }
				Picker("Keep Touch Bar awake", selection: $awake) { ForEach(KeepAwake.allCases, id: \.self) { Text($0.title).tag($0) } }
					.onChange(of: awake) { PurrPlayer.shared.keepAwake = $0 }
				Picker("Battery saver", selection: $saver) { ForEach(BatterySaver.allCases, id: \.self) { Text($0.title).tag($0) } }
					.onChange(of: saver) { PurrPlayer.shared.batterySaver = $0 }
			}
			Section_("Lyrics language") {
				Picker("Script", selection: $script) { ForEach(LyricsScript.allCases, id: \.self) { Text($0.title).tag($0) } }
					.onChange(of: script) { PurrPlayer.shared.lyricsScript = $0 }
				if #available(macOS 15.0, *) {
					Picker("Translate", selection: $translate) { ForEach(TranslateTarget.allCases, id: \.self) { Text($0.title).tag($0) } }
						.onChange(of: translate) { PurrPlayer.shared.translateTarget = $0 }
				} else {
					Hint("Lyrics translation needs macOS 15 or newer.")
				}
				Button("Search lyrics again for this song") { LyricsStore.shared.reload() }
			}
		}
	}
}

// MARK: - AI Writing Tools

public final class WritingToolsPreferencePane: PockAIPreferencePane {
	public override var keys: [String] { ["pockai.ai.onlyOnSelection", "pockai.ai.applyDirectly", "pockai.ai.modes"] }
	public override func makeContent() -> AnyView { AnyView(WritingToolsPaneView(model: SettingsModel.shared)) }
}

private struct WritingToolsPaneView: View {
	@ObservedObject var model: SettingsModel
	@State private var modes = Set(SharedSettings.touchBarModes)

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Section_("Gemini API key (free)") {
				HStack {
					SecureField("Paste your key", text: $model.apiKey)
					Button("Save") { model.saveKey() }
					Button(model.testing ? "Testing…" : "Test") { model.testKey() }.disabled(model.testing)
				}
				HStack {
					Text(model.keyStatus).font(.system(size: 11)).foregroundColor(.secondary)
					Spacer()
					Button("Get a free key") { NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/apikey")!) }
				}
			}
			Section_("Touch Bar") {
				Toggle("Show ✨ only while text is selected", isOn: setting("pockai.ai.onlyOnSelection", true, notify: SharedSettings.didChange))
				Toggle("Proofread, Rewrite… replace the text straight away (Undo on the bar)", isOn: setting("pockai.ai.applyDirectly", false, notify: SharedSettings.didChange))
				Text("Buttons on the Touch Bar").font(.system(size: 11, weight: .medium))
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 4) {
					ForEach(WritingMode.allCases) { mode in
						Toggle(mode.title, isOn: Binding(
							get: { modes.contains(mode) },
							set: { on in
								if on { modes.insert(mode) } else if modes.count > 1 { modes.remove(mode) }
								SharedSettings.touchBarModes = WritingMode.allCases.filter { modes.contains($0) }
							}))
					}
				}
				HStack {
					Button("Open Writing Tools panel  ⌃⌥W") { Task { @MainActor in await WritingToolsController.shared.show() } }
					Button("Templates & all settings…") { PockAISettings.open(tab: .ai) }
				}
			}
			Section_("Permission") {
				PermissionLine(title: "Accessibility (read & replace selected text)", granted: { AXIsProcessTrusted() }, ask: { SelectionBridge.requestTrust() })
			}
		}
		.onAppear { model.refresh() }
	}
}

// MARK: - Subtitles

public final class SubtitlesPreferencePane: PockAIPreferencePane {
	public override var keys: [String] {
		["pockai.subs.visible", "pockai.subs.width", "pockai.subs.hideEmpty", "pockai.subs.bridge", "pockai.subs.local",
		 "pockai.subs.ocr", "pockai.subs.offset", "pockai.subs.autoFull"]
	}
	public override func makeContent() -> AnyView { AnyView(SubtitlesPaneView()) }
}

private struct SubtitlesPaneView: View {
	private let n = SubtitleSettings.didChange
	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Section_("Where subtitles come from") {
				Toggle("Browser extension: Netflix, YouTube, Prime Video, Disney+, Max, Hulu…", isOn: setting("pockai.subs.bridge", true, notify: n))
				HStack {
					Button("Install Browser Extension…") { PockAISettings.installBrowserExtension() }
					Hint("Chrome, Edge, Brave, Arc")
				}
				Toggle(".srt / .vtt next to local movies (IINA, VLC, QuickTime…)", isOn: setting("pockai.subs.local", true, notify: n))
				HStack {
					Text("File timing")
					Stepper(value: setting("pockai.subs.offset", 0.0, notify: n), in: -30...30, step: 0.5) {
						Text(String(format: "%+.1f s", UserDefaults.standard.double(forKey: "pockai.subs.offset")))
					}
					Button("Load Subtitle File…") { PockAISettings.chooseSubtitleFile() }
				}
				if #available(macOS 14.0, *) {
					Toggle("Read subtitles from the screen (Safari, any app)", isOn: setting("pockai.subs.ocr", false, notify: n))
					PermissionLine(title: "Screen Recording (only for reading from the screen)", granted: { CGPreflightScreenCaptureAccess() }, ask: { CGRequestScreenCaptureAccess() })
				} else {
					Hint("Reading subtitles from the screen needs macOS 14 or newer.")
				}
			}
			Section_("On the Touch Bar") {
				Toggle("Show subtitles (long-press the widget to hide / show)", isOn: setting("pockai.subs.visible", true, notify: n))
				WidthSlider(title: "Width", binding: setting("pockai.subs.width", 360.0, notify: n), range: 200...800)
				Toggle("Hide when there are no subtitles", isOn: setting("pockai.subs.hideEmpty", true, notify: n))
				Toggle("If the bar is full, show subtitles full-width automatically", isOn: setting("pockai.subs.autoFull", true, notify: n))
				Hint("Tap the widget for big full-width subtitles; tap again to go back.")
			}
		}
	}
}

// MARK: - System Monitor

public final class SystemMonitorPreferencePane: PockAIPreferencePane {
	public override var keys: [String] { ["pockai.sysmon.network", "pockai.sysmon.interval", "pockai.sysmon.bars"] }
	public override func makeContent() -> AnyView {
		AnyView(VStack(alignment: .leading, spacing: 10) {
			Section_("Display") {
				Picker("Show", selection: setting("pockai.sysmon.network", false)) {
					Text("CPU & memory").tag(false)
					Text("Network speed").tag(true)
				}
				Toggle("Usage bars under the numbers", isOn: setting("pockai.sysmon.bars", true))
				Picker("Update every", selection: setting("pockai.sysmon.interval", 2.0)) {
					Text("1 second").tag(1.0); Text("2 seconds").tag(2.0); Text("5 seconds").tag(5.0)
				}
				Hint("Tap: switch view · Long-press: Activity Monitor. Updates only while the widget is visible.")
			}
		})
	}
}

// MARK: - Clipboard

public final class ClipboardPreferencePane: PockAIPreferencePane {
	public override var keys: [String] { ["pockai.clip.limit", "pockai.clip.paste"] }
	public override func makeContent() -> AnyView {
		AnyView(VStack(alignment: .leading, spacing: 10) {
			Section_("History") {
				Picker("Remember", selection: setting("pockai.clip.limit", 15)) {
					ForEach([5, 10, 15, 25, 50], id: \.self) { Text("\($0) items").tag($0) }
				}
				Toggle("Tapping an item pastes it (off: only copies it)", isOn: setting("pockai.clip.paste", true))
				Button("Clear history now") { NotificationCenter.default.post(name: PockAIWidgetSettingsDidChange, object: "pockai.clip.clear") }
				Hint("Text only, kept in memory (never written to disk). Copies from password managers are skipped.")
			}
		})
	}
}

// MARK: - Timer

public final class TimerPreferencePane: PockAIPreferencePane {
	public override var keys: [String] { ["pockai.timer.length", "pockai.timer.sound", "pockai.timer.flash"] }
	public override func makeContent() -> AnyView {
		AnyView(VStack(alignment: .leading, spacing: 10) {
			Section_("Timer") {
				Picker("Default length", selection: setting("pockai.timer.length", 1500.0)) {
					ForEach([5, 10, 15, 20, 25, 30, 45, 50, 60, 90], id: \.self) { Text("\($0) minutes").tag(Double($0 * 60)) }
				}
				Picker("Sound when done", selection: setting("pockai.timer.sound", "Glass")) {
					ForEach(["Glass", "Hero", "Ping", "Purr", "Submarine", "Funk", "None"], id: \.self) { Text($0).tag($0) }
				}
				Toggle("Flash the Touch Bar when done", isOn: setting("pockai.timer.flash", true))
				Hint("Tap: start / pause · Swipe right / left: ±5 minutes · Long-press: reset")
			}
		})
	}
}

// MARK: - Quick Actions

public final class QuickActionsPreferencePane: PockAIPreferencePane {
	public static let all = ["Screenshot", "Lock", "Display sleep", "Dark mode", "Focus"]
	public override var keys: [String] { ["pockai.quick.enabled"] }
	public override func makeContent() -> AnyView { AnyView(QuickActionsPaneView()) }
}

private struct QuickActionsPaneView: View {
	@State private var enabled = Set(UserDefaults.standard.stringArray(forKey: "pockai.quick.enabled") ?? QuickActionsPreferencePane.all)
	var body: some View {
		Section_("Buttons") {
			ForEach(QuickActionsPreferencePane.all, id: \.self) { name in
				Toggle(name, isOn: Binding(
					get: { enabled.contains(name) },
					set: { on in
						if on { enabled.insert(name) } else if enabled.count > 1 { enabled.remove(name) }
						UserDefaults.standard.set(QuickActionsPreferencePane.all.filter { enabled.contains($0) }, forKey: "pockai.quick.enabled")
						NotificationCenter.default.post(name: PockAIWidgetSettingsDidChange, object: "pockai.quick.enabled")
					}))
			}
			Hint("Dark mode asks once for permission to control System Events.")
		}
	}
}

// MARK: - Next Event

public final class CalendarPreferencePane: PockAIPreferencePane {
	public override var keys: [String] { ["pockai.calendar.hideEmpty", "pockai.calendar.location", "pockai.calendar.warn", "pockai.calendar.allDay"] }
	public override func makeContent() -> AnyView {
		AnyView(VStack(alignment: .leading, spacing: 10) {
			Section_("Next event") {
				Toggle("Hide when nothing is left today", isOn: setting("pockai.calendar.hideEmpty", false))
				Toggle("Show the location", isOn: setting("pockai.calendar.location", true))
				Toggle("Include all-day events", isOn: setting("pockai.calendar.allDay", false))
				Picker("Turn red before it starts", selection: setting("pockai.calendar.warn", 10)) {
					ForEach([0, 5, 10, 15, 30], id: \.self) { Text($0 == 0 ? "Never" : "\($0) minutes").tag($0) }
				}
				Hint("Tap the widget to open Calendar.")
			}
		})
	}
}

// MARK: - Games

public final class GamesPreferencePane: PockAIPreferencePane {
	public override var keys: [String] { ["pockai.games.sound"] }
	public override func makeContent() -> AnyView {
		AnyView(VStack(alignment: .leading, spacing: 10) {
			Section_("Games") {
				Toggle("Sounds", isOn: setting("pockai.games.sound", true))
				HStack {
					ForEach(Array(["Dino Run", "Whack-a-Mole", "Perfect Stop", "Memory"].enumerated()), id: \.offset) { i, name in
						VStack {
							Text(name).font(.system(size: 11, weight: .medium))
							Text("★ \(UserDefaults.standard.integer(forKey: "pockai.games.best.\(i)"))").foregroundColor(.secondary)
						}
						.frame(maxWidth: .infinity)
					}
				}
				Button("Reset best scores") {
					(0...3).forEach { UserDefaults.standard.removeObject(forKey: "pockai.games.best.\($0)") }
				}
				Hint("Tap 🎮 Games on the Touch Bar, pick a game; ✕ goes back.")
			}
		})
	}
}
