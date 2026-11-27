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

// MARK: - Lyrics (LRCLIB, a free public lyrics database)

struct LyricLine {
    var t: Double
    var text: String
    var words: [(at: Double?, end: Int)]   // end = UTF-16 offset just past the word

    init(t: Double, text: String, starts: [Int: Double] = [:]) {
        self.t = t
        self.text = text
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"\S+"#)
        words = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (starts[$0.range.location], $0.range.location + $0.range.length)
        }
    }
}

struct Lyrics {
    var lines: [LyricLine]
    var synced: Bool

    // (current line, how many UTF-16 units of it are already sung, next line)
    func at(_ t: Double, duration: Double) -> (String, Int, String) {
        guard !lines.isEmpty else { return ("", 0, "") }
        let i: Int
        if synced {
            guard let idx = lines.lastIndex(where: { $0.t <= t + 0.2 }) else { return ("♪", 1, lines[0].text) }
            i = idx
        } else {
            i = duration > 0 ? min(lines.count - 1, max(0, Int(t / duration * Double(lines.count)))) : 0
        }
        let line = lines[i]
        let next = i + 1 < lines.count ? lines[i + 1].text : ""
        if line.text.isEmpty { return ("♪", 1, next) }
        guard synced, !line.words.isEmpty else { return (line.text, (line.text as NSString).length, next) }

        var lit = 0
        if line.words.allSatisfy({ $0.at != nil }) {
            // Enhanced LRC: exact word start times.
            for w in line.words where w.at! <= t + 0.05 { lit = w.end }
        } else {
            // Line timing only: spread the words, weighted by length, over the time the line is likely sung.
            let gap = (i + 1 < lines.count ? lines[i + 1].t : line.t + 6) - line.t
            var starts: [Double] = []
            var acc = 0.0
            var prevEnd = 0
            for w in line.words {
                starts.append(acc)
                acc += Double(w.end - prevEnd) + 1
                prevEnd = w.end
            }
            let singing = max(0.3, min(gap * 0.9, acc * 0.07 + 0.3))
            let f = (t - line.t) / singing * acc
            for (k, w) in line.words.enumerated() where starts[k] <= f { lit = w.end }
        }
        return (line.text, lit, next)
    }

    func index(at t: Double, duration: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        if synced { return lines.lastIndex(where: { $0.t <= t + 0.2 }) }
        return duration > 0 ? min(lines.count - 1, max(0, Int(t / duration * Double(lines.count)))) : 0
    }

    // A music-only stretch (intro or a blank line in the lyrics) around time t: (start, end) in seconds.
    func gap(at t: Double) -> (Double, Double)? {
        guard synced, !lines.isEmpty else { return nil }
        guard let i = lines.lastIndex(where: { $0.t <= t + 0.2 }) else {
            return lines[0].t > 1.5 ? (0, lines[0].t) : nil
        }
        guard lines[i].text.isEmpty, i + 1 < lines.count else { return nil }
        return (lines[i].t, lines[i + 1].t)
    }

    static func parse(_ r: [String: Any]) -> Lyrics? {
        if r["instrumental"] as? Bool == true { return Lyrics(lines: [LyricLine(t: 0, text: "♪ Instrumental")], synced: false) }
        if let s = r["syncedLyrics"] as? String, !s.isEmpty {
            let lineRe = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
            let wordRe = try! NSRegularExpression(pattern: #"<(\d+):(\d+(?:\.\d+)?)>"#)
            var out: [LyricLine] = []
            for raw in s.components(separatedBy: .newlines) {
                let ns = raw as NSString
                let ms = lineRe.matches(in: raw, range: NSRange(location: 0, length: ns.length))
                guard let last = ms.last else { continue }
                let body = ns.substring(from: last.range.location + last.range.length) as NSString
                // Strip <mm:ss.xx> word tags, remembering the clean-text offset each one points at.
                var clean = ""
                var starts: [Int: Double] = [:]
                var cursor = 0
                for m in wordRe.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                    clean += body.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                    let t = (Double(body.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(body.substring(with: m.range(at: 2))) ?? 0)
                    let spaces = body.substring(from: m.range.location + m.range.length).prefix { $0 == " " }.utf16.count
                    starts[(clean as NSString).length + spaces] = t
                    cursor = m.range.location + m.range.length
                }
                clean += body.substring(from: cursor)
                let lead = clean.prefix { $0 == " " }.utf16.count
                let text = clean.trimmingCharacters(in: .whitespaces)
                var shifted: [Int: Double] = [:]
                for (k, v) in starts { shifted[k - lead] = v }
                for m in ms {
                    let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
                    out.append(LyricLine(t: t, text: text, starts: shifted))
                }
            }
            if !out.isEmpty { return Lyrics(lines: out.sorted { $0.t < $1.t }, synced: true) }
        }
        if let p = r["plainLyrics"] as? String {
            let ls = p.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !ls.isEmpty { return Lyrics(lines: ls.map { LyricLine(t: 0, text: $0) }, synced: false) }
        }
        return nil
    }
}

enum LyricsScript: String, CaseIterable {
    case auto, urdu, hindi, roman

    var title: String {
        switch self {
        case .auto: return "Auto (best match)"
        case .urdu: return "Urdu script first (اردو)"
        case .hindi: return "Hindi script first (हिन्दी)"
        case .roman: return "Roman letters"
        }
    }

    static var current: LyricsScript {
        get { LyricsScript(rawValue: UserDefaults.standard.string(forKey: "lyricsScript") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lyricsScript") }
    }

    // Which script a lyrics text is mostly written in.
    static func detect(_ text: String) -> LyricsScript {
        var arabic = 0, devanagari = 0, latin = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: arabic += 1
            case 0x0900...0x097F: devanagari += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if arabic > 0 && arabic >= devanagari && arabic >= latin { return .urdu }
        if devanagari > 0 && devanagari >= latin { return .hindi }
        return .roman
    }
}

extension LyricsScript {
    /// Settings → Lyrics: show Hindi-script (Devanagari) lyrics in Roman Urdu letters. On by default.
    static var romaniseHindi: Bool {
        get { UserDefaults.standard.object(forKey: "pockai.lyrics.romanHindi") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pockai.lyrics.romanHindi") }
    }
}

extension Lyrics {
    /// Devanagari → Roman Urdu letters ("zindagi", "mohabbat", "main", "hai"); timing kept, word tags dropped.
    func romanised() -> Lyrics {
        Lyrics(lines: lines.map { LyricLine(t: $0.t, text: Self.romanise($0.text)) }, synced: synced)
    }

    static func romanise(_ text: String) -> String {
        RomanUrdu.transliterate(text)
    }
}
