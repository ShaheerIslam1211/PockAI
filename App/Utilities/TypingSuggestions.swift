//
//  TypingSuggestions.swift
//  PockAI
//
//  Typing suggestions on PockAI's bar, in every app (Notes, Claude, Word, Chrome, WhatsApp…).
//
//  macOS only shows its suggestions in the app's own part of the Touch Bar, which PockAI covers,
//  and many apps (Electron apps like Claude, WhatsApp, VS Code) never show them at all. PockAI follows
//  what you type (Accessibility permission), asks macOS's own suggestion engine for completions,
//  corrections and next-word predictions, and shows them over the widgets while you type.
//  Tap one to type it. The widgets come back when you stop typing, click, or press Esc / Return.
//
//  Never active in password fields (macOS hides keystrokes there from every app).
//

import AppKit
import Carbon.HIToolbox
import PockAIKit

final class TypingSuggestions: NSObject {

	static let shared = TypingSuggestions()
	static let enabledKey = "pockai.typing"
	static let maxSuggestions = 6

	static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

	/// Called with true when suggestions should cover the widgets, false to give the bar back.
	var onShowingChange: ((Bool) -> Void)?
	/// The strip PockAI's bar shows over the widgets.
	private(set) lazy var view: NSStackView = {
		let stack = NSStackView()
		stack.orientation = .horizontal
		stack.distribution = .fill
		stack.spacing = 6
		stack.translatesAutoresizingMaskIntoConstraints = false
		stack.heightAnchor.constraint(equalToConstant: 30).isActive = true
		stack.isHidden = true
		return stack
	}()

	private(set) var isShowing = false
	/// Text typed since the last click / Return / app switch (what suggestions are based on).
	private var context = ""
	private var candidates: [(range: NSRange, text: String)] = []
	private var monitors: [Any] = []
	private var requestTimer: Timer?
	private var hideTimer: Timer?
	private var requestSerial = 0
	private var ignoreTypingUntil = Date.distantPast
	private let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
	/// Marks keystrokes PockAI types itself, so they aren't read back as typing.
	private static let syntheticMarker: Int64 = 0x504F_434B

	// MARK: Start / stop

	func start() {
		NotificationCenter.default.addObserver(forName: PockAIWidgetSettingsDidChange, object: nil, queue: .main) { [weak self] note in
			guard (note.object as? String) == Self.enabledKey else { return }
			self?.update()
		}
		NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
			self?.reset()
		}
		// Test hook: same as tapping suggestion N (0-based).
		DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.typing"), object: nil, queue: .main) { [weak self] note in
			guard let self, let index = Int(note.object as? String ?? ""), self.view.arrangedSubviews.indices.contains(index),
				  let button = self.view.arrangedSubviews[index] as? NSButton else { return }
			self.choose(button)
		}
		update()
	}

	private func update() {
		if Self.isEnabled, monitors.isEmpty {
			if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.keyDown($0) }) {
				monitors.append(keys)
			}
			if let mouse = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.reset() }) {
				monitors.append(mouse)
			}
		} else if !Self.isEnabled {
			monitors.forEach(NSEvent.removeMonitor)
			monitors.removeAll()
			reset()
		}
	}

	// MARK: Following typing

	private func keyDown(_ event: NSEvent) {
		if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return }
		// Keys PockAI just typed for a suggestion (the marker doesn't always survive delivery).
		if Date() < ignoreTypingUntil { return }
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		if flags.contains(.command) || flags.contains(.control) { reset(); return }
		switch Int(event.keyCode) {
		case kVK_Delete:
			guard !context.isEmpty else { reset(); return }
			context.removeLast()
		case kVK_ForwardDelete, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
			 kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
			 kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
			reset(); return
		default:
			guard let chars = event.characters, !chars.isEmpty,
				  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else {
				return
			}
			context += chars
			if context.count > 160 { context = String(context.suffix(120)) }
		}
		scheduleRequest()
	}

	private func scheduleRequest() {
		requestTimer?.invalidate()
		requestTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in self?.requestCandidates() }
	}

	private func requestCandidates() {
		guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { show([]); return }
		requestSerial += 1
		let serial = requestSerial
		let text = context
		let caret = NSRange(location: (text as NSString).length, length: 0)
		NSSpellChecker.shared.requestCandidates(forSelectedRange: caret, in: text, types: NSTextCheckingAllSystemTypes,
												options: nil, inSpellDocumentWithTag: spellTag) { [weak self] _, results in
			DispatchQueue.main.async {
				guard let self, serial == self.requestSerial, text == self.context else { return }
				self.show(self.pick(results, in: text))
			}
		}
	}

	/// Up to six useful suggestions: a spelling fix first, then completions / next words, never what you already typed.
	private func pick(_ results: [NSTextCheckingResult], in text: String) -> [(range: NSRange, text: String)] {
		let ns = text as NSString
		var picked: [(range: NSRange, text: String)] = []
		var seen = Set<String>()
		func add(_ range: NSRange, _ replacement: String) {
			let clean = replacement.trimmingCharacters(in: .whitespaces)
			guard !clean.isEmpty, NSMaxRange(range) == ns.length else { return }
			let typed = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
			guard clean != typed, seen.insert(clean.lowercased()).inserted else { return }
			picked.append((range, clean))
		}
		// Misspelled word being typed → the best guess first.
		let wordRange = currentWordRange(in: ns)
		if wordRange.length > 2 {
			let misspelled = NSSpellChecker.shared.checkSpelling(of: text, startingAt: wordRange.location, language: nil, wrap: false,
																 inSpellDocumentWithTag: spellTag, wordCount: nil)
			if misspelled.location == wordRange.location,
			   let guess = NSSpellChecker.shared.guesses(forWordRange: wordRange, in: text, language: nil, inSpellDocumentWithTag: spellTag)?.first {
				add(wordRange, guess)
			}
		}
		for result in results {
			if let replacement = result.replacementString { add(result.range, replacement) }
			if picked.count >= Self.maxSuggestions { break }
		}
		// Fill the rest: words that start like this one, then close spellings ("meting" → meeting).
		if wordRange.length > 0, picked.count < Self.maxSuggestions {
			let checker = NSSpellChecker.shared
			let language = checker.language()
			let more = (checker.completions(forPartialWordRange: wordRange, in: text, language: language, inSpellDocumentWithTag: spellTag) ?? [])
				+ (wordRange.length > 2 ? checker.guesses(forWordRange: wordRange, in: text, language: language, inSpellDocumentWithTag: spellTag) ?? [] : [])
			for word in more where picked.count < Self.maxSuggestions { add(wordRange, word) }
		}
		// Emoji for the word being typed, the word just finished, or the top suggestion ("love" → ❤️ 😍).
		// macOS sometimes suggests an emoji itself: keep those with the other emoji at the end.
		var emoji: [String] = picked.map(\.text).filter(Self.isEmoji)
		picked.removeAll { Self.isEmoji($0.text) }
		let lastWord = ns.substring(to: ns.length).split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
		emoji = Array(emoji.prefix(3))
		// The word being typed, the word just finished, the top suggestion, then the rest of the sentence.
		let earlier = ns.substring(to: ns.length).split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init).reversed()
		for word in [ns.substring(with: wordRange), lastWord, picked.first?.text ?? ""] + Array(earlier.prefix(6)) where emoji.count < 3 {
			for e in EmojiSuggestions.emoji(for: word) where emoji.count < 3 && !emoji.contains(e) { emoji.append(e) }
		}
		// Nothing matches: the emoji you picked last (😂 ❤️ 👍 until you pick some), so there are always emoji to tap.
		for e in Self.recentEmoji where emoji.count < 3 && !emoji.contains(e) { emoji.append(e) }
		let words = Array(picked.prefix(Self.maxSuggestions - 2))
		let end = NSRange(location: ns.length, length: 0)
		return words + emoji.map { (end, $0) }
	}

	private static let recentKey = "touchplay.typing.recentEmoji"
	static var recentEmoji: [String] {
		get { UserDefaults.standard.stringArray(forKey: recentKey) ?? ["😂", "❤️", "👍"] }
		set { UserDefaults.standard.set(Array(newValue.prefix(6)), forKey: recentKey) }
	}

	private static func isEmoji(_ text: String) -> Bool {
		text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }
	}

	private func currentWordRange(in ns: NSString) -> NSRange {
		var start = ns.length
		while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)),
			  CharacterSet.letters.contains(scalar) || scalar == "'" {
			start -= 1
		}
		return NSRange(location: start, length: ns.length - start)
	}

	// MARK: Showing

	private func show(_ list: [(range: NSRange, text: String)]) {
		if !TPSafely("typing suggestions", { showUnsafe(list) }) {
			// Something went wrong building the strip: give the bar back rather than leave it half-built.
			candidates = []
			view.arrangedSubviews.forEach { $0.removeFromSuperview() }
			setShowing(false)
		}
	}

	private func showUnsafe(_ list: [(range: NSRange, text: String)]) {
		candidates = list
		for button in view.arrangedSubviews {
			view.removeArrangedSubview(button)
			button.removeFromSuperview()
		}
		var firstWord: NSButton?
		for (index, candidate) in list.enumerated() {
			let button = NSButton(title: candidate.text, target: self, action: #selector(choose(_:)))
			button.tag = index
			button.translatesAutoresizingMaskIntoConstraints = false
			if Self.isEmoji(candidate.text) {
				// Emoji: small fixed buttons at the end.
				button.font = .systemFont(ofSize: 18)
				button.bezelColor = NSColor(white: 0.18, alpha: 1)
				button.widthAnchor.constraint(equalToConstant: 50).isActive = true
				button.setContentHuggingPriority(.required, for: .horizontal)
			} else {
				button.bezelColor = index == 0 ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.22, alpha: 1)
				button.font = .systemFont(ofSize: 14)
				button.lineBreakMode = .byTruncatingTail
				button.setContentCompressionResistancePriority(.init(1), for: .horizontal)
				button.setContentHuggingPriority(.init(1), for: .horizontal)
			}
			view.addArrangedSubview(button)
			// Words share the space equally. Only link the widths once both buttons are in the strip:
			// a constraint between views with no common parent throws and takes the whole app down.
			if !Self.isEmoji(candidate.text) {
				if let firstWord { button.widthAnchor.constraint(equalTo: firstWord.widthAnchor).isActive = true } else { firstWord = button }
			}
		}
		if firstWord == nil, !list.isEmpty {
			// Only emoji: fill the rest so they stay small.
			let spacer = NSView()
			spacer.setContentHuggingPriority(.init(1), for: .horizontal)
			view.addArrangedSubview(spacer)
		}
		let wantsShow = !list.isEmpty && AppController.shared.isVisible
		setShowing(wantsShow)
		hideTimer?.invalidate()
		if wantsShow {
			hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.setShowing(false) }
		}
	}

	private func setShowing(_ showing: Bool) {
		guard showing != isShowing else { return }
		isShowing = showing
		view.isHidden = !showing
		onShowingChange?(showing)
	}

	func reset() {
		requestTimer?.invalidate()
		requestSerial += 1
		context = ""
		candidates = []
		hideTimer?.invalidate()
		setShowing(false)
	}

	// MARK: Typing a suggestion

	@objc private func choose(_ sender: NSButton) {
		guard candidates.indices.contains(sender.tag) else { return }
		let candidate = candidates[sender.tag]
		if Self.isEmoji(candidate.text) {
			Self.recentEmoji = [candidate.text] + Self.recentEmoji.filter { $0 != candidate.text }
		}
		let ns = context as NSString
		let deleteCount = (ns.substring(with: candidate.range) as NSString).length
		let leadingSpace = candidate.range.length == 0 && !(context.last?.isWhitespace ?? true)
		let insert = (leadingSpace ? " " : "") + candidate.text + " "
		ignoreTypingUntil = Date().addingTimeInterval(0.35)
		type(backspaces: deleteCount, text: insert)
		context = ns.replacingCharacters(in: candidate.range, with: "") + insert
		scheduleRequest()
	}

	private func type(backspaces: Int, text: String) {
		let source = CGEventSource(stateID: .hidSystemState)
		func post(_ event: CGEvent?) {
			guard let event else { return }
			event.flags = []
			event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
			event.post(tap: .cghidEventTap)
		}
		for _ in 0..<backspaces {
			post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
			post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
		}
		let units = Array(text.utf16)
		var index = 0
		while index < units.count {
			let chunk = Array(units[index..<min(index + 16, units.count)])
			for down in [true, false] {
				let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
				event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
				post(event)
			}
			index += 16
		}
	}
}
