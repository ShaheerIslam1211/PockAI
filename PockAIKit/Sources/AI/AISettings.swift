import AppKit
import Foundation

/// Where the Gemini API key lives. Saved in PockAI's own preferences; if you already pasted a key
/// into the PocketAI Mac app, PockAI picks it up from there so nothing needs re-entering.
public enum KeyStore {
	private static let keyName = "geminiAPIKey"
	/// PocketAI for Mac's preferences domain.
	private static let pocketAIDomain = "com.pocketai.mb27.mac"

	public static var apiKey: String {
		if let own = UserDefaults.standard.string(forKey: keyName), !own.isEmpty { return own }
		if let shared = UserDefaults(suiteName: pocketAIDomain)?.string(forKey: keyName), !shared.isEmpty { return shared }
		return ""
	}

	public static var hasKey: Bool { !apiKey.isEmpty }

	/// True when the key was found in the PocketAI app rather than saved in PockAI.
	public static var isFromPocketAI: Bool {
		(UserDefaults.standard.string(forKey: keyName) ?? "").isEmpty && hasKey
	}

	public static func save(_ key: String) {
		UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyName)
	}

	/// Gemini keys are long tokens without spaces; this catches pasting a sentence by mistake.
	public static func looksLikeKey(_ text: String) -> Bool {
		let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.count >= 30 && text.count <= 200 && !text.contains(" ")
	}
}

/// Writing Tools settings + the user's own one-tap templates.
public enum SharedSettings {
	private static let d = UserDefaults.standard

	public struct Template: Codable, Identifiable, Hashable {
		public var id = UUID()
		public var title: String
		public var instruction: String
		public init(title: String, instruction: String) { self.title = title; self.instruction = instruction }
	}

	public static let defaultTemplates = [
		Template(title: "Funny", instruction: "Rewrite the text to be light-hearted and funny while keeping the meaning."),
		Template(title: "Hashtags", instruction: "Keep the text and add 3-5 fitting hashtags at the end."),
		Template(title: "Polite No", instruction: "Rewrite the text as a polite, friendly way of saying no."),
		Template(title: "Roman Urdu", instruction: "Translate the text into natural Roman Urdu (Urdu written with English letters)."),
	]

	public static var templates: [Template] {
		get {
			let data = d.data(forKey: "templates") ?? UserDefaults(suiteName: "com.pocketai.mb27.mac")?.data(forKey: "templates")
			guard let data, let saved = try? JSONDecoder().decode([Template].self, from: data) else { return defaultTemplates }
			return saved
		}
		set { d.set(try? JSONEncoder().encode(newValue), forKey: "templates") }
	}

	/// Show the ✨ button only while text is selected (otherwise always visible, dimmed).
	public static var onlyOnSelection: Bool {
		get { d.object(forKey: "pockai.ai.onlyOnSelection") as? Bool ?? true }
		set { d.set(newValue, forKey: "pockai.ai.onlyOnSelection"); NotificationCenter.default.post(name: didChange, object: nil) }
	}

	/// Edit modes (Proofread, Rewrite…) replace the text straight away, with Undo on the Touch Bar.
	public static var applyDirectly: Bool {
		get { d.object(forKey: "pockai.ai.applyDirectly") as? Bool ?? false }
		set { d.set(newValue, forKey: "pockai.ai.applyDirectly"); NotificationCenter.default.post(name: didChange, object: nil) }
	}

	/// The modes shown on the Touch Bar, in order.
	public static var touchBarModes: [WritingMode] {
		get {
			let raw = d.stringArray(forKey: "pockai.ai.modes") ?? []
			let modes = raw.compactMap(WritingMode.init(rawValue:))
			return modes.isEmpty ? WritingMode.allCases : modes
		}
		set { d.set(newValue.map(\.rawValue), forKey: "pockai.ai.modes") }
	}

	public static let didChange = Notification.Name("pockai.ai.settingsChanged")
}
