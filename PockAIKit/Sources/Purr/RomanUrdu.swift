import Foundation

/// Hindi script (Devanagari) → Roman Urdu, the way people write Hindi/Urdu lyrics in English letters:
/// "मुझको इतना बताए कोई" → "Mujhko itna bataye koi", "ज़िन्दगी" → "zindagi", "मोहब्बत" → "mohabbat".
///
/// Generic transliteration keeps every silent "a" ("mujhako itanā batāe") and the accents; this drops the
/// "a" that isn't spoken (Hindi schwa deletion), uses common spellings (aa/ee/oo, sh, ch, kh, w), and knows
/// the most frequent short words (hai, main, mein, nahin, wo, ye, kya).
enum RomanUrdu {

    static func transliterate(_ text: String) -> String {
        var out = ""
        var word = ""
        for ch in text {
            if ch.unicodeScalars.allSatisfy({ (0x0900...0x097F).contains($0.value) }) {
                word.append(ch)
            } else {
                out += convert(word)
                word = ""
                out.append(ch == "।" || ch == "॥" ? "." : ch)
            }
        }
        out += convert(word)
        out = out.replacingOccurrences(of: "।", with: ".").replacingOccurrences(of: "॥", with: ".")
        // Lines start with a capital, like typed lyrics.
        if let first = out.firstIndex(where: { $0.isLetter }), text.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) {
            out.replaceSubrange(first...first, with: String(out[first]).uppercased())
        }
        return out
    }

    // MARK: Words

    private static let common: [String: String] = [
        "है": "hai", "हैं": "hain", "मैं": "main", "में": "mein", "नहीं": "nahin", "नही": "nahin",
        "यह": "ye", "ये": "ye", "वह": "wo", "वो": "wo", "कि": "ki", "और": "aur", "क्या": "kya", "क्यों": "kyun", "क्यूँ": "kyun",
        "हूँ": "hoon", "हूं": "hoon", "हो": "ho", "तुम": "tum", "हम": "hum", "था": "tha", "थी": "thi", "थे": "the",
        "जो": "jo", "तो": "to", "भी": "bhi", "ही": "hi", "से": "se", "के": "ke", "की": "ki", "का": "ka", "को": "ko",
        "पे": "pe", "पर": "par", "ना": "na", "न": "na", "मुझे": "mujhe", "तुझे": "tujhe", "कहीं": "kahin",
        "यहाँ": "yahan", "वहाँ": "wahan", "जहाँ": "jahan", "कहाँ": "kahan", "यहां": "yahan", "वहां": "wahan",
        "जहां": "jahan", "कहां": "kahan", "हाँ": "haan", "हां": "haan", "आज": "aaj", "कभी": "kabhi",
        "जिंदगी": "zindagi", "जिन्दगी": "zindagi", "ज़िंदगी": "zindagi", "ज़िन्दगी": "zindagi",
        "इश्क": "ishq", "इश्क़": "ishq", "ख्वाब": "khwab", "ख़्वाब": "khwab", "ज़रा": "zara", "जरा": "zara",
        "सजना": "sajna", "मेरे": "mere", "तेरे": "tere", "रे": "re", "ओ": "o", "ए": "ae", "अब": "ab", "सब": "sab",
        "एक": "ek", "दो": "do", "बस": "bas", "यूँ": "yun", "यूं": "yun", "क्यूं": "kyun", "मगर": "magar", "लेकिन": "lekin",
        "अच्छा": "acha", "अच्छी": "achi", "अच्छे": "ache", "बच्चा": "bacha", "सच्चा": "sacha", "कुछ": "kuch",
    ]

    private static func convert(_ word: String) -> String {
        guard !word.isEmpty else { return "" }
        if let known = common[word] { return known }
        let units = parse(word)
        guard !units.isEmpty else { return word }
        let keep = schwaKept(units)
        var out = ""
        for (i, u) in units.enumerated() {
            let last = i == units.count - 1
            // च्छ is written "chh", not "chchh".
            if u.vowel == .none, u.consonant == "ch", i + 1 < units.count, units[i + 1].consonant.hasPrefix("ch") {
                continue
            }
            out += u.consonant
            var vowel: String
            switch u.vowel {
            case .none: vowel = ""
            case .inherent: vowel = keep[i] ? "a" : ""
            case .sign(let v): vowel = roman(v, last: last, afterVowel: false, isLastUnit: last)
            case .independent(let v):
                let afterVowel = i > 0 && units[i - 1].vowel.isVowel
                vowel = roman(v, last: last, afterVowel: afterVowel, isLastUnit: last)
            }
            // A final long "aa" is written "a" (tera, dekha); before a nasal at the end keep it long (jahaan).
            if case .sign("ा") = u.vowel, last, !u.nasal { vowel = "a" }
            if case .independent("आ") = u.vowel, last, !u.nasal, units.count > 1 { vowel = "a" }
            out += vowel
            if u.nasal { out += (u.consonant.isEmpty && vowel.isEmpty) ? "" : "n" }
            if u.visarga { out += "h" }
        }
        return out
    }

    // MARK: Parsing

    private enum Vowel: Equatable {
        case inherent, none, sign(Character), independent(Character)
        var isVowel: Bool { self != .none }
    }

    private struct Unit {
        var consonant: String
        var vowel: Vowel
        var nasal = false
        var visarga = false
    }

    private static let consonants: [Character: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n", "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n", "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m", "य": "y", "र": "r", "ल": "l", "व": "w",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h", "ळ": "l",
        // Nukta letters (precomposed): Urdu sounds.
        "क़": "q", "ख़": "kh", "ग़": "gh", "ज़": "z", "ड़": "r", "ढ़": "rh", "फ़": "f", "य़": "y",
    ]
    private static let nukta: [String: String] = ["k": "q", "kh": "kh", "g": "gh", "j": "z", "d": "r", "dh": "rh", "ph": "f", "y": "y"]
    private static let independents: Set<Character> = ["अ", "आ", "इ", "ई", "उ", "ऊ", "ऋ", "ए", "ऐ", "ओ", "औ", "ऑ", "ऍ"]
    private static let signs: Set<Character> = ["ा", "ि", "ी", "ु", "ू", "ृ", "े", "ै", "ो", "ौ", "ॉ", "ॅ"]

    private static func parse(_ word: String) -> [Unit] {
        var units: [Unit] = []
        // Work on scalars so a nukta / vowel sign that Swift joined into one Character is still seen.
        for scalar in word.unicodeScalars {
            let ch = Character(scalar)
            if let c = consonants[ch] {
                units.append(Unit(consonant: c, vowel: .inherent))
            } else if independents.contains(ch) {
                units.append(Unit(consonant: "", vowel: .independent(ch)))
            } else if signs.contains(ch), !units.isEmpty {
                units[units.count - 1].vowel = .sign(ch)
            } else if scalar.value == 0x094D, !units.isEmpty {            // virama: no vowel
                units[units.count - 1].vowel = .none
            } else if scalar.value == 0x093C, !units.isEmpty {            // nukta after a consonant
                let c = units[units.count - 1].consonant
                units[units.count - 1].consonant = nukta[c] ?? c
            } else if scalar.value == 0x0902 || scalar.value == 0x0901, !units.isEmpty {   // anusvara / chandrabindu
                units[units.count - 1].nasal = true
            } else if scalar.value == 0x0903, !units.isEmpty {            // visarga
                units[units.count - 1].visarga = true
            }
        }
        return units
    }

    /// Which inherent "a"s are spoken. Hindi drops the last one, and a middle one between a vowel and a
    /// consonant-with-vowel (sapna, karna, dharkan) — but not after a cluster or nasal (zindagi, mohabbat).
    private static func schwaKept(_ units: [Unit]) -> [Bool] {
        var keep = units.map { $0.vowel == .inherent }
        let n = units.count
        if n > 1, units[n - 1].vowel == .inherent {
            // Keep it after a cluster that can't end a word ("mitra" stays, "dil" drops it).
            let clusterBefore = n >= 2 && units[n - 2].vowel == .none
            keep[n - 1] = clusterBefore && ["r", "y", "w"].contains(units[n - 1].consonant)
        }
        guard n >= 3 else { return keep }
        for i in stride(from: n - 2, through: 1, by: -1) where units[i].vowel == .inherent && !units[i].nasal {
            let prev = units[i - 1], next = units[i + 1]
            let prevHasVowel = prev.vowel == .inherent ? keep[i - 1] : prev.vowel != .none
            let nextHasVowel = next.vowel == .inherent ? keep[i + 1] : next.vowel != .none
            let prevHeavy = prev.nasal || (i >= 2 && units[i - 2].vowel == .none)
            if prevHasVowel && nextHasVowel && !prevHeavy && !units[i].consonant.isEmpty {
                keep[i] = false
            }
        }
        return keep
    }

    private static func roman(_ v: Character, last: Bool, afterVowel: Bool, isLastUnit: Bool) -> String {
        switch v {
        case "अ": return "a"
        case "आ", "ा": return "aa"
        case "इ", "ि": return afterVowel ? "yi" : "i"
        case "ई", "ी": return last ? "i" : (afterVowel ? "yi" : "ee")
        case "उ", "ु": return "u"
        case "ऊ", "ू": return last ? "u" : "oo"
        case "ऋ", "ृ": return "ri"
        case "ए", "े": return afterVowel ? "ye" : "e"
        case "ऐ", "ै": return "ai"
        case "ओ", "ो": return "o"
        case "औ", "ौ": return "au"
        case "ऑ", "ॉ": return "o"
        case "ऍ", "ॅ": return "e"
        default: return ""
        }
    }
}
