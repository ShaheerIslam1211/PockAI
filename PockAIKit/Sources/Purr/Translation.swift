import AppKit
import QuartzCore
import CoreText
import CoreImage
import CoreAudio
import Accelerate
import NaturalLanguage
import SwiftUI
import Translation
import IOKit.ps
import IOKit.pwr_mgt
import CoreGraphics

// MARK: - Lyrics translation (Apple's on-device translator: free, offline once a language is downloaded)

enum TranslateTarget: String, CaseIterable {
    case off, english, romanHindi

    var title: String {
        switch self {
        case .off: return "Off"
        case .english: return "To English"
        case .romanHindi: return "To Roman Hindi"
        }
    }

    static var current: TranslateTarget {
        get { TranslateTarget(rawValue: UserDefaults.standard.string(forKey: "translateTo") ?? "") ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "translateTo") }
    }
}

@available(macOS 15.0, *)
enum LyricsTranslator {
    enum Outcome {
        case lines([String])          // one translation per lyric line
        case note(String)             // nothing to show per line, just a short explanation
        case needsDownload(Locale.Language, Locale.Language)
    }

    static func translate(_ lyrics: Lyrics, to target: TranslateTarget) async -> Outcome {
        let texts = lyrics.lines.map(\.text)
        let sample = texts.filter { !$0.isEmpty }.joined(separator: "\n")
        guard target != .off, !sample.isEmpty else { return .lines([]) }
        let script = LyricsScript.detect(sample)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        var lang = recognizer.dominantLanguage?.rawValue ?? "und"
        if script == .urdu { lang = "ur" }
        if script == .hindi { lang = "hi" }

        let dst: Locale.Language
        switch target {
        case .english:
            if lang == "en" { return .lines([]) }
            dst = Locale.Language(identifier: "en")
        case .romanHindi:
            // Already Hindi: just show it in Roman letters, no translation needed.
            if lang == "hi" { return .lines(texts.map { $0.isEmpty ? "" : Lyrics.romanise($0) }) }
            // Already Roman Hindi/Urdu (anything in Latin letters that isn't English): nothing to add.
            if script == .roman && lang != "en" { return .lines([]) }
            dst = Locale.Language(identifier: "hi")
        case .off:
            return .lines([])
        }
        let src = Locale.Language(identifier: lang)
        let status = await LanguageAvailability().status(from: src, to: dst)
        switch status {
        case .unsupported:
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            return .note("No offline translation for \(name)")
        case .supported:
            return .needsDownload(src, dst)
        default:
            break
        }
        do {
            let unique = Array(Set(texts.filter { !$0.isEmpty }))
            let requests = unique.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            var map: [String: String] = [:]
            let responses: [TranslationSession.Response]
            if #available(macOS 26.0, *) {
                responses = try await TranslationSession(installedSource: src, target: dst).translations(from: requests)
            } else {
                responses = try await HiddenTranslator.translate(requests, from: src, to: dst)
            }
            for r in responses {
                if let id = r.clientIdentifier, let i = Int(id) { map[unique[i]] = r.targetText }
            }
            return .lines(texts.map { t in
                guard let out = map[t] else { return "" }
                return target == .romanHindi ? Lyrics.romanise(out) : out
            })
        } catch {
            return .note("Translation failed")
        }
    }
}

// One-time language download: the system shows its own consent sheet from this small window.
@available(macOS 15.0, *)
struct TranslationDownloadView: View {
    let configuration: TranslationSession.Configuration
    let done: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text("TouchPlay Lyrics").font(.headline)
            Text("Download the languages to translate lyrics on this Mac.").font(.callout).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 320)
        .translationTask(configuration) { session in
            try? await session.prepareTranslation()
            await MainActor.run { done() }
        }
    }
}


// macOS 15: a TranslationSession can only come from SwiftUI's .translationTask, so run it in a tiny invisible window.
@available(macOS 15.0, *)
@MainActor
enum HiddenTranslator {
    private static var windows: [NSWindow] = []

    static func translate(_ requests: [TranslationSession.Request], from src: Locale.Language, to dst: Locale.Language) async throws -> [TranslationSession.Response] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TranslationSession.Response], Error>) in
            var window: NSWindow?
            var finished = false
            let view = HiddenTranslationView(configuration: .init(source: src, target: dst)) { session in
                do {
                    let out = try await session.translations(from: requests)
                    if !finished { finished = true; cont.resume(returning: out) }
                } catch {
                    if !finished { finished = true; cont.resume(throwing: error) }
                }
                await MainActor.run {
                    window?.close()
                    windows.removeAll { $0 === window }
                }
            }
            let w = NSWindow(contentRect: NSRect(x: -100, y: -100, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.contentView = NSHostingView(rootView: view)
            w.orderFrontRegardless()
            window = w
            windows.append(w)
            // Never wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if !finished { finished = true; cont.resume(throwing: CancellationError()) }
                w.close()
                windows.removeAll { $0 === w }
            }
        }
    }
}

@available(macOS 15.0, *)
private struct HiddenTranslationView: View {
    let configuration: TranslationSession.Configuration
    let work: (TranslationSession) async -> Void
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(configuration) { session in await work(session) }
    }
}
