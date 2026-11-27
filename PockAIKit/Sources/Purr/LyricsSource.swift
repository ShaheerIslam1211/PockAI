import AppKit
import Foundation

// MARK: - Lyrics search (free sources, no account or key needed)
//
//  • LRCLIB (lrclib.net) — open lyrics database, synced LRC.
//  • NetEase Cloud Music (music.163.com) — huge catalogue incl. Bollywood/Punjabi/K-pop, synced LRC,
//    often in Roman letters for Hindi songs.
//
//  Works for songs and for music videos (YouTube in Chrome/Safari, VLC, IINA…): video titles such as
//  "Kesariya - Brahmāstra | Ranbir Kapoor | Arijit Singh" or "Artist - Song (Official Video)" are split
//  into song/artist guesses, and the channel name ("T-Series", "Sony Music India") isn't required to match.

enum LyricsSource {
    static func norm(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    /// One candidate, in LRCLIB's shape: trackName, artistName, duration (s), syncedLyrics, plainLyrics, instrumental.
    typealias Candidate = [String: Any]

    private struct Guess {
        var song: String
        var artist: String        // "" = unknown (video): judged by the full title and the length instead
    }

    /// Video-title noise that isn't part of the song name.
    static func stripVideoNoise(_ s: String) -> String {
        var t = s
        let patterns = [
            #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|remaster|full song|from |ost)[^\)\]]*[\)\]]"#,
            #"\s*\b(ft|feat|featuring)\.?\s.*$"#,
            #"\s*\b(full (video|song|audio)|video song|lyrical( video)?|official (music )?video|lyrics?)\b.*$"#,
        ]
        for p in patterns { t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive]) }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:|\"'"))
    }

    // A result needs its title to match, and its artist to match (or, for videos, to appear in the full title,
    // or the length to be the same). Synced lyrics are used as synced only when the length is within 4 s.
    static func fetch(title: String, artist: String, duration: Double, rawTitle: String? = nil,
                      script pref: LyricsScript = LyricsScript.current, done: @escaping (Lyrics?) -> Void) {
        let fullTitle = norm(rawTitle ?? title)
        let channel = artist.trimmingCharacters(in: .whitespaces)

        // --- Guesses: (song, artist) readings of what's playing.
        var guesses: [Guess] = []
        let cleaned = stripVideoNoise(title)
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: "-–—|:"))
            .map { stripVideoNoise($0) }.filter { norm($0).count >= 2 }
        if parts.count >= 2 {
            guesses.append(Guess(song: parts[1], artist: parts[0]))   // "Artist - Song"
            guesses.append(Guess(song: parts[0], artist: parts[1]))   // "Song - Movie/Artist"
        }
        if !channel.isEmpty { guesses.append(Guess(song: parts.first ?? cleaned, artist: channel)) }
        // Song name alone (videos, or a channel name instead of an artist).
        for p in parts.prefix(2) { guesses.append(Guess(song: p, artist: "")) }
        if parts.isEmpty { guesses.append(Guess(song: cleaned, artist: channel)) }
        var seen = Set<String>()
        guesses = guesses.filter { seen.insert(norm($0.song) + "|" + norm($0.artist)).inserted && norm($0.song).count >= 2 }

        // --- Matching and ranking.
        let dur: (Candidate) -> Double = { abs((($0["duration"] as? NSNumber)?.doubleValue ?? 0) - duration) }
        let goodSynced: (Candidate) -> Bool = { ($0["syncedLyrics"] as? String)?.isEmpty == false && (duration <= 0 || dur($0) <= 4) }
        let scriptOf: (Candidate) -> LyricsScript = {
            LyricsScript.detect(($0["syncedLyrics"] as? String) ?? ($0["plainLyrics"] as? String) ?? "")
        }
        // Auto: lyrics you can read without Hindi script come first (Roman, English, Urdu); Hindi script is converted later.
        let preferred: (Candidate) -> Bool = { pref == .auto ? scriptOf($0) != .hindi : scriptOf($0) == pref }

        func accept(_ r: Candidate, _ g: Guess) -> Bool {
            let track = norm(stripVideoNoise(r["trackName"] as? String ?? "")), who = norm(r["artistName"] as? String ?? "")
            let song = norm(g.song)
            guard !track.isEmpty, track == song || track.contains(song) || (track.count >= 4 && song.contains(track)) else { return false }
            let art = norm(g.artist)
            if art.count >= 2, (who.count >= 3 && (who.contains(art) || art.contains(who))) || track.contains(art) { return true }
            // Unknown artist: one of the result's artists must be named in the full title, or the length must match.
            let names = (r["artistName"] as? String ?? "").components(separatedBy: CharacterSet(charactersIn: ",&/;")).map(norm)
            if names.contains(where: { $0.count >= 3 && fullTitle.contains($0) }) { return true }
            return g.artist.isEmpty && duration > 0 && dur(r) <= 3
        }

        let lock = NSLock()
        var found: [Candidate] = []
        func add(_ list: [Candidate], _ g: Guess) {
            lock.lock(); found += list.filter { accept($0, g) }; lock.unlock()
        }
        func satisfied() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return found.contains { goodSynced($0) && preferred($0) }
        }

        func finish() {
            lock.lock(); let all = found; lock.unlock()
            let rank: (Candidate) -> (Int, Int, Double) = { (goodSynced($0) ? 0 : 1, preferred($0) ? 0 : 1, dur($0)) }
            let synced = all.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }.sorted { rank($0) < rank($1) }
            var chosen: Candidate?
            var result: Lyrics?
            if let best = synced.first, duration <= 0 || dur(best) <= 4 {
                chosen = best
                result = Lyrics.parse(best)
            } else if let any = synced.first ?? all.sorted(by: { (preferred($0) ? 0 : 1) < (preferred($1) ? 0 : 1) }).first,
                      var l = Lyrics.parse(["plainLyrics": any["plainLyrics"] ?? "", "syncedLyrics": any["syncedLyrics"] ?? "",
                                            "instrumental": any["instrumental"] ?? false]) {
                l.synced = false
                chosen = any
                result = l
            }
            // Hindi script (Devanagari) → Roman Urdu letters, unless you asked for Hindi script.
            if let c = chosen, let r = result, scriptOf(c) == .hindi, pref != .hindi, LyricsScript.romaniseHindi {
                result = r.romanised()
            }
            DispatchQueue.main.async { done(result) }
        }

        let group = DispatchGroup()

        // LRCLIB: each guess as a field search, then as free text; stops early on a good preferred match.
        var queue: [(Guess, Bool)] = guesses.flatMap { g in g.artist.isEmpty ? [(g, false)] : [(g, true), (g, false)] }
        group.enter()
        func nextLRCLIB() {
            guard !satisfied(), !queue.isEmpty else { group.leave(); return }
            let (g, fields) = queue.removeFirst()
            var c = URLComponents(string: "https://lrclib.net/api/search")!
            c.queryItems = fields ? [URLQueryItem(name: "track_name", value: g.song), URLQueryItem(name: "artist_name", value: g.artist)]
                                  : [URLQueryItem(name: "q", value: (g.song + " " + g.artist).trimmingCharacters(in: .whitespaces))]
            get(c.url!) { data in
                let arr = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Candidate]) ?? []
                add(arr, g)
                nextLRCLIB()
            }
        }
        nextLRCLIB()

        // NetEase: the first two readings, in parallel with LRCLIB.
        for g in guesses.prefix(3) {
            group.enter()
            NetEase.search(g.song + " " + g.artist) { list in
                let matches = list.filter { accept($0, g) }.prefix(2)
                guard !matches.isEmpty else { group.leave(); return }
                let inner = DispatchGroup()
                for m in matches {
                    inner.enter()
                    NetEase.lyrics(for: m) { full in
                        if let full { add([full], g) }
                        inner.leave()
                    }
                }
                inner.notify(queue: .global()) { group.leave() }
            }
        }

        group.notify(queue: .global()) { finish() }
    }

    static func get(_ url: URL, _ done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("TouchPlay/1.0 (https://github.com/)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in done(data) }.resume()
    }
}

// MARK: - NetEase Cloud Music (public web API)

private enum NetEase {
    static func search(_ query: String, _ done: @escaping ([LyricsSource.Candidate]) -> Void) {
        var c = URLComponents(string: "https://music.163.com/api/search/get")!
        c.queryItems = [URLQueryItem(name: "s", value: query.trimmingCharacters(in: .whitespaces)),
                        URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "limit", value: "8")]
        LyricsSource.get(c.url!) { data in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let songs = ((json?["result"] as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
            done(songs.compactMap { s in
                guard let id = s["id"] as? NSNumber, let name = s["name"] as? String else { return nil }
                let artists = (s["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
                let ms = (s["duration"] as? NSNumber)?.doubleValue ?? 0
                return ["neteaseID": id, "trackName": name, "artistName": artists, "duration": NSNumber(value: ms / 1000)]
            })
        }
    }

    static func lyrics(for song: LyricsSource.Candidate, _ done: @escaping (LyricsSource.Candidate?) -> Void) {
        guard let id = song["neteaseID"] as? NSNumber else { done(nil); return }
        let url = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1")!
        LyricsSource.get(url) { data in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard let lrc = (json?["lrc"] as? [String: Any])?["lyric"] as? String, !lrc.isEmpty else { done(nil); return }
            // Drop the credit lines NetEase puts first ("[00:00.000] 作词 : …", "Composer: …").
            let credit = try! NSRegularExpression(pattern: #"^\[[^\]]*\]\s*[^\[\]]{0,24}\s[:：]\s"#)
            let lines = lrc.components(separatedBy: .newlines).filter {
                let ns = $0 as NSString
                return credit.firstMatch(in: $0, range: NSRange(location: 0, length: ns.length)) == nil
            }
            let text = lines.joined(separator: "\n")
            if text.contains("纯音乐") {
                var out = song; out["instrumental"] = true; done(out); return
            }
            let timed = text.range(of: #"\[\d+:\d+"#, options: .regularExpression) != nil
            var out = song
            if timed { out["syncedLyrics"] = text } else { out["plainLyrics"] = text }
            done(out)
        }
    }
}
