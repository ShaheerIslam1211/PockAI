import AppKit
import Foundation

/// Minimal client for the Gemini generateContent REST API.
/// The key comes from `KeyStore`; the model from each target's Info.plist (Config/Base.xcconfig).
public struct GeminiClient: Sendable {
    public static let shared = GeminiClient()

    private static let fallbackModel = "gemini-flash-lite-latest"

    var apiKey: String { KeyStore.apiKey }

    var model: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "GeminiModel") as? String ?? ""
        return name.isEmpty ? Self.fallbackModel : name
    }

    private static let baseRules = """
    You are a writing tool built into the Mac's Touch Bar.
    Output ONLY the final text. No quotes around it, no explanations, no preamble, no markdown headings.
    Keep names, numbers, links and emojis. Keep the original language unless told to translate.
    Always use correct spelling, grammar and punctuation in what you write.
    """

    /// Runs one of the preset writing modes.
    /// - Parameter notes: extra guidance, e.g. what to say in a reply.
    public func run(_ mode: WritingMode, text: String, notes: String? = nil) async throws -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.noText }

        // Very long text: rewrite it piece by piece so nothing gets cut off (modes that summarise see it whole).
        if text.count > Self.chunkLimit, mode.appliesDirectly {
            var parts: [String] = []
            for chunk in Self.chunks(of: text) {
                parts.append(try await generate(system: Self.baseRules + "\nTask: " + mode.instruction, prompt: "Text:\n\(chunk)"))
            }
            return parts.joined(separator: "\n")
        }

        var prompt = mode == .reply ? "Message to reply to:\n\(text)" : "Text:\n\(text)"
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nUser's notes: \(notes)"
        }
        return try await generate(system: Self.baseRules + "\nTask: " + mode.instruction, prompt: prompt)
    }

    static let chunkLimit = 6000

    /// Splits text at line breaks (or sentence ends) into pieces of at most `chunkLimit` characters.
    static func chunks(of text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { pieces.append(current); current = "" } }
        for line in text.components(separatedBy: "\n") {
            if line.count > chunkLimit {
                flush()
                var sentence = ""
                for word in line.split(separator: " ", omittingEmptySubsequences: false) {
                    sentence += (sentence.isEmpty ? "" : " ") + word
                    if sentence.count > chunkLimit - 200, word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!") || sentence.count > chunkLimit {
                        pieces.append(sentence)
                        sentence = ""
                    }
                }
                if !sentence.isEmpty { pieces.append(sentence) }
            } else if current.count + line.count + 1 > chunkLimit {
                flush()
                current = line
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        flush()
        return pieces
    }

    /// Applies a free-form instruction, e.g. "make it sound more confident".
    public func custom(_ instruction: String, text: String) async throws -> String {
        try await generate(system: Self.baseRules + "\nTask: " + instruction, prompt: "Text:\n\(text)")
    }

    /// Writes new text from a description, optionally continuing what's already in the text box.
    public func compose(_ request: String, context: String) async throws -> String {
        var prompt = "Write: \(request)"
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { prompt += "\n\nText already in the box (for context, don't repeat it):\n\(context)" }
        return try await generate(
            system: Self.baseRules + "\nTask: Write what the user asks for, ready to send. Match the language the user writes in.",
            prompt: prompt,
            temperature: 0.8
        )
    }

    /// Answers a general question (used by the "Ask PocketAI" Siri action).
    public func ask(_ question: String) async throws -> String {
        try await generate(
            system: "You are a helpful assistant answering by voice. Be brief and clear, 1-4 sentences, plain text.",
            prompt: question,
            temperature: 0.7
        )
    }

    func generate(system: String, prompt: String, temperature: Double = 0.4) async throws -> String {
        do {
            return try await request(model: model, system: system, prompt: prompt, temperature: temperature)
        } catch AIError.badResponse(let message) where message.hasPrefix("404") && model != Self.fallbackModel {
            // The configured model was retired; use the alias that always points at a live model.
            return try await request(model: Self.fallbackModel, system: system, prompt: prompt, temperature: temperature)
        }
    }

    private func request(model: String, system: String, prompt: String, temperature: Double) async throws -> String {
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": temperature,
                "thinkingConfig": ["thinkingLevel": "minimal"],
                "maxOutputTokens": 16384,
            ],
        ]
        let parts = try await post(model: model, body: body, timeout: 60)
        let text = parts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AIError.badResponse("Gemini returned an empty answer (it may have been blocked by safety filters).")
        }
        return text
    }

    /// Waits for connectivity instead of failing at once when the network is switching (Wi-Fi ↔ cellular).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private func post(model: String, body: [String: Any], timeout: TimeInterval) async throws -> [[String: Any]] {
        guard !apiKey.isEmpty else { throw AIError.missingKey }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Mobile networks drop requests now and then; retry quickly before giving up.
        var attempt = 0
        var result: (Data, URLResponse)?
        while result == nil {
            do {
                result = try await Self.session.data(for: request)
            } catch let error as URLError {
                attempt += 1
                if attempt >= 3 || error.code == .cancelled {
                    switch error.code {
                    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                        throw AIError.network("No internet connection.")
                    case .timedOut:
                        throw AIError.network("Gemini took too long to answer. Tap Retry.")
                    default:
                        throw AIError.network("Couldn't reach Gemini (\(error.code.rawValue)). Tap Retry.")
                    }
                }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }
        let (data, response) = result!

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            switch status {
            case 429: throw AIError.badResponse("429 Free limit reached for now. Try again in a minute.")
            case 400 where message.localizedCaseInsensitiveContains("api key"),
                 401, 403: throw AIError.badResponse("Your Gemini API key isn't valid. Paste a new one in PockAI → AI Settings.")
            default: throw AIError.badResponse("\(status) \(message)")
            }
        }

        let candidates = json?["candidates"] as? [[String: Any]]
        return (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
    }
}
