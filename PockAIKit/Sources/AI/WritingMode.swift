import AppKit
import Foundation

/// The text actions shared by the app, keyboard, share sheet and Siri.
public enum WritingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fix, rewrite, friendly, formal, shorter, longer, summarize, keyPoints, list, table, english, reply, emoji

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fix: "Proofread"
        case .rewrite: "Rewrite"
        case .friendly: "Friendly"
        case .formal: "Professional"
        case .shorter: "Concise"
        case .longer: "Expand"
        case .summarize: "Summary"
        case .keyPoints: "Key Points"
        case .list: "List"
        case .table: "Table"
        case .english: "To English"
        case .reply: "Reply"
        case .emoji: "Emojify"
        }
    }

    public var symbol: String {
        switch self {
        case .fix: "text.magnifyingglass"
        case .rewrite: "arrow.triangle.2.circlepath"
        case .friendly: "face.smiling"
        case .formal: "briefcase"
        case .shorter: "arrow.down.right.and.arrow.up.left"
        case .longer: "arrow.up.left.and.arrow.down.right"
        case .summarize: "text.alignleft"
        case .keyPoints: "list.bullet.circle"
        case .list: "list.bullet"
        case .table: "tablecells"
        case .english: "globe"
        case .reply: "arrowshape.turn.up.left"
        case .emoji: "face.smiling.inverse"
        }
    }

    /// What the progress label says while running, e.g. "Rewriting…".
    public var progressTitle: String {
        switch self {
        case .fix: "Proofreading"
        case .summarize, .keyPoints: "Summarizing"
        case .list: "Making a list"
        case .table: "Making a table"
        case .english: "Translating"
        case .reply: "Writing a reply"
        default: "Rewriting"
        }
    }

    /// Modes that change the user's own text are applied straight away (with Revert),
    /// like Apple's Writing Tools. The rest are shown first so the user can choose.
    public var appliesDirectly: Bool {
        switch self {
        case .fix, .rewrite, .friendly, .formal, .shorter, .longer, .english, .emoji: true
        case .summarize, .keyPoints, .list, .table, .reply: false
        }
    }

    public var instruction: String {
        switch self {
        case .fix:
            "Proofread the text. Fix grammar, spelling, punctuation and capitalization. Keep the author's words, tone and meaning; change only what is wrong."
        case .rewrite:
            "Paraphrase the text so it reads clearly and naturally, with fresh wording. Keep the same meaning, tone and roughly the same length."
        case .friendly:
            "Rewrite the text in a warm, friendly, casual tone suitable for chatting with friends."
        case .formal:
            "Rewrite the text in a polished, professional tone suitable for work email, LinkedIn or official messages."
        case .shorter:
            "Make the text as concise as possible while keeping every important point."
        case .longer:
            "Expand the text with more detail and smoother flow, keeping the same message and tone. About twice as long."
        case .summarize:
            "Summarize the text in one short paragraph."
        case .keyPoints:
            "Extract the key points as short bullet points starting with '•'."
        case .list:
            "Turn the text into a clean list, one item per line starting with '•'."
        case .table:
            "Organize the information into a simple plain-text table: a header row, then one row per line, columns separated by ' | '. No markdown dividers."
        case .english:
            "Translate the text into natural, fluent English. The input may be Urdu, Hindi, Roman Urdu/Hindi (Hinglish) or any other language."
        case .reply:
            "Write a natural reply to the message. If the user adds notes about what to say, follow them. Match the language and tone of the message."
        case .emoji:
            "Rewrite the text with a few fitting emojis added. Keep the wording otherwise the same."
        }
    }
}

public enum AIError: LocalizedError {
    case missingKey, noText, badResponse(String), network(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No Gemini API key yet. PockAI menu → AI Settings… and paste your free key."
        case .noText: "There's no text to work with."
        case .badResponse(let message): message
        case .network(let message): message
        }
    }
}
