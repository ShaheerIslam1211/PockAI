//
//  EmojiSuggestions.swift
//  TouchPlay
//
//  Emoji for the word you're typing ("love" → ❤️ 😍, "haha" → 😂, "pizza" → 🍕, "pakistan" → 🇵🇰).
//  A hand-picked list for everyday words (English and Roman Urdu/Hindi) comes first; everything else is
//  looked up in macOS's own emoji names (the same names the Character Viewer uses).
//

import Foundation

enum EmojiSuggestions {

	/// Up to `limit` emoji for `word` (any case). Empty when nothing fits.
	static func emoji(for word: String, limit: Int = 3) -> [String] {
		let key = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
		guard key.count >= 2 else { return [] }
		var out: [String] = curated[key] ?? []
		// Simple plurals / -ing: "hearts" → heart, "dogs" → dog, "partying" → party.
		if out.isEmpty {
			for stem in [String(key.dropLast()), String(key.dropLast(3)), key + "e"] where stem.count >= 3 {
				if let hit = curated[stem] { out = hit; break }
			}
		}
		var found = index[key] ?? []
		if found.isEmpty && out.isEmpty {
			for stem in [String(key.dropLast()), String(key.dropLast(2)), String(key.dropLast(3))] where stem.count >= 3 {
				if let hit = index[stem] { found = hit; break }
			}
		}
		for e in found where !out.contains(e) { out.append(e) }
		return Array(out.prefix(limit))
	}

	// MARK: Everyday words

	private static let curated: [String: [String]] = {
		let groups: [(String, [String])] = [
			("love loving loved lov luv pyar pyaar ishq mohabbat", ["❤️", "😍", "🥰"]),
			("heart dil", ["❤️", "💖", "💕"]),
			("haha hahaha lol lmao rofl funny hilarious hasi", ["😂", "🤣", "😆"]),
			("happy glad khush khushi yay", ["😊", "😄", "🥳"]),
			("smile smiling muskurahat", ["😊", "🙂", "😁"]),
			("sad upset dukhi udaas cry crying rona", ["😢", "😭", "💔"]),
			("angry mad gussa annoyed", ["😠", "😡", "🤬"]),
			("sorry maaf maafi", ["😔", "🙏", "🥺"]),
			("please plz pls", ["🙏", "🥺"]),
			("thanks thank thankyou thx shukriya shukria dhanyavad", ["🙏", "😊", "💐"]),
			("ok okay okk theek thik", ["👌", "👍"]),
			("yes yeah yup haan han ji", ["👍", "✅"]),
			("no nope nahi nahin", ["👎", "🙅", "❌"]),
			("cool awesome nice great zabardast kamaal", ["😎", "🔥", "👏"]),
			("wow omg amazing", ["😮", "🤩", "😱"]),
			("fire lit hot", ["🔥"]),
			("party celebrate congrats congratulations mubarak", ["🎉", "🥳", "🎊"]),
			("birthday bday salgirah", ["🎂", "🎉", "🎁"]),
			("kiss kisses", ["😘", "💋"]),
			("hug hugs", ["🤗"]),
			("sleep sleepy tired neend", ["😴", "🥱"]),
			("think thinking hmm soch", ["🤔"]),
			("hello hi hey salam salaam assalamualaikum namaste", ["👋", "😊"]),
			("bye goodbye allahhafiz khudahafiz", ["👋"]),
			("good acha achha badhiya", ["👍", "👌"]),
			("bad bura", ["👎"]),
			("money paisa paise cash rupees", ["💰", "💵", "🤑"]),
			("music song gana gaana", ["🎵", "🎶", "🎧"]),
			("food khana hungry bhook", ["🍔", "🍕", "😋"]),
			("tea chai chaye", ["☕", "🫖"]),
			("coffee", ["☕"]),
			("pizza", ["🍕"]),
			("biryani rice chawal", ["🍛", "🍚"]),
			("cricket", ["🏏"]),
			("football soccer", ["⚽"]),
			("win won winner jeet", ["🏆", "🥇", "🎉"]),
			("work office kaam", ["💼", "💻"]),
			("study padhai exam", ["📚", "✏️"]),
			("car gari gaadi", ["🚗"]),
			("home ghar", ["🏠"]),
			("rain barish baarish", ["🌧️", "☔"]),
			("sun sunny dhoop", ["☀️"]),
			("night raat", ["🌙", "✨"]),
			("morning subah", ["🌅", "☀️"]),
			("eid", ["🌙", "🕌", "🎉"]),
			("pray dua namaz", ["🤲", "🙏"]),
			("friend friends dost yaar yaara", ["🤝", "👫", "😊"]),
			("baby bacha", ["👶", "🍼"]),
			("mom ammi maa", ["👩", "❤️"]),
			("dad abbu papa", ["👨", "❤️"]),
			("strong power", ["💪"]),
			("clap well done shabash", ["👏"]),
			("star", ["⭐", "🌟"]),
			("sick bimar", ["🤒", "🤧"]),
			("cold thand", ["🥶"]),
			("scared dar darr", ["😨", "😱"]),
			("shy sharm", ["🙈", "😊"]),
			("wink", ["😉"]),
			("cute pyara pyari", ["🥰", "😊"]),
			("beautiful pretty khoobsurat", ["😍", "✨"]),
			("dance nacho", ["💃", "🕺"]),
			("phone mobile call", ["📱", "📞"]),
			("time waqt", ["⏰", "⌛"]),
			("idea", ["💡"]),
			("done finished", ["✅"]),
			("rocket launch", ["🚀"]),
			("pakistan", ["🇵🇰"]),
			("india", ["🇮🇳"]),
		]
		var map: [String: [String]] = [:]
		for (words, emoji) in groups {
			for w in words.split(separator: " ") { map[String(w)] = emoji }
		}
		return map
	}()

	// MARK: macOS emoji names

	/// word → emoji, built once from CoreEmoji's English names ("face with tears of joy" → joy: 😂).
	private static let index: [String: [String]] = {
		let path = "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources/en.lproj/AppleName.strings"
		guard let names = NSDictionary(contentsOfFile: path) as? [String: String] else { return [:] }
		let skip: Set<String> = ["face", "with", "of", "the", "and", "a", "an", "in", "on", "symbol", "sign", "button", "mark",
								 "light", "medium", "dark", "skin", "tone", "person", "man", "woman", "people", "flag", "small",
								 "large", "big", "black", "white", "open", "closed", "up", "down", "left", "right", "arrow", "squared"]
		var map: [String: [String]] = [:]
		// Shorter names are the more direct match ("pizza" before "slice of pizza with …").
		for (emoji, name) in names.sorted(by: { $0.value.count < $1.value.count }) {
			let lower = name.lowercased()
			if lower.hasPrefix("flag of ") {
				let country = String(lower.dropFirst(8)).replacingOccurrences(of: "the ", with: "")
					.filter { $0.isLetter }
				map[country, default: []].append(emoji)
				continue
			}
			let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
			guard words.count <= 4 else { continue }
			for w in words where w.count >= 3 && !skip.contains(w) {
				if (map[w]?.count ?? 0) < 3 { map[w, default: []].append(emoji) }
			}
		}
		return map
	}()
}
