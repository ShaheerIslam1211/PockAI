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

enum LyricsSource {
    static func norm(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    // "A - B" video titles could be either way round, so both readings are tried alongside the reported title/artist.
    // A result needs its title AND artist to match; synced lyrics are used as synced only when the length is within 4 s,
    // since a different cut (video intro, radio edit) shifts every line.
    static func fetch(title: String, artist: String, duration: Double, script pref: LyricsScript = LyricsScript.current,
                      done: @escaping (Lyrics?) -> Void) {
        var pairs: [(song: String, artist: String)] = []
        let parts = title.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count == 2 {
            pairs.append((parts[1], parts[0]))
            pairs.append((parts[0], parts[1]))
        }
        if !artist.isEmpty { pairs.append((title, artist)) }
        pairs = pairs.filter { norm($0.song).count >= 2 && norm($0.artist).count >= 2 }
        // Each reading is tried as a field search, then as free text (catches entries titled "Artist - Song (Official Video)").
        var queue = pairs.flatMap { [($0, true), ($0, false)] }
        var found: [[String: Any]] = []
        let dur: ([String: Any]) -> Double = { abs((($0["duration"] as? NSNumber)?.doubleValue ?? 0) - duration) }
        let goodSynced: ([String: Any]) -> Bool = { ($0["syncedLyrics"] as? String)?.isEmpty == false && (duration <= 0 || dur($0) <= 4) }
        let scriptOf: ([String: Any]) -> LyricsScript = {
            LyricsScript.detect(($0["syncedLyrics"] as? String) ?? ($0["plainLyrics"] as? String) ?? "")
        }
        let preferred: ([String: Any]) -> Bool = { pref == .auto || scriptOf($0) == pref }

        func accept(_ r: [String: Any], _ pair: (song: String, artist: String)) -> Bool {
            let track = norm(r["trackName"] as? String ?? ""), who = norm(r["artistName"] as? String ?? "")
            let song = norm(pair.song), art = norm(pair.artist)
            guard !track.isEmpty, track == song || track.contains(song) || (track.count >= 4 && song.contains(track)) else { return false }
            return (who.count >= 3 && (who.contains(art) || art.contains(who))) || track.contains(art)
        }

        // Good timing beats script; among equally good matches the preferred script wins, then the closest length.
        func finish() {
            let rank: ([String: Any]) -> (Int, Int, Double) = { (goodSynced($0) ? 0 : 1, preferred($0) ? 0 : 1, dur($0)) }
            let synced = found.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }.sorted { rank($0) < rank($1) }
            var chosen: [String: Any]?
            var result: Lyrics?
            if let best = synced.first, duration <= 0 || dur(best) <= 4 {
                chosen = best
                result = Lyrics.parse(best)
            } else if let any = synced.first ?? found.sorted(by: { (preferred($0) ? 0 : 1) < (preferred($1) ? 0 : 1) }).first,
                      var l = Lyrics.parse(["plainLyrics": any["plainLyrics"] ?? "", "syncedLyrics": any["syncedLyrics"] ?? "", "instrumental": any["instrumental"] ?? false]) {
                l.synced = false
                chosen = any
                result = l
            }
            // Asked for Urdu or Roman but only Hindi script exists: show it in Roman letters.
            if let c = chosen, let r = result, (pref == .urdu || pref == .roman), scriptOf(c) == .hindi {
                result = r.romanised()
            }
            DispatchQueue.main.async { done(result) }
        }

        func next() {
            guard !found.contains(where: { goodSynced($0) && preferred($0) }), !queue.isEmpty else { finish(); return }
            let (pair, fields) = queue.removeFirst()
            var c = URLComponents(string: "https://lrclib.net/api/search")!
            c.queryItems = fields ? [URLQueryItem(name: "track_name", value: pair.song), URLQueryItem(name: "artist_name", value: pair.artist)]
                                  : [URLQueryItem(name: "q", value: pair.song + " " + pair.artist)]
            var req = URLRequest(url: c.url!)
            req.timeoutInterval = 8
            req.setValue("TouchBarPlayer/1.0", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, _, _ in
                let arr = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
                found += arr.filter { accept($0, pair) }
                next()
            }.resume()
        }
        next()
    }
}
