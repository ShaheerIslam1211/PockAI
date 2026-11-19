import AppKit

/// Fetches lyrics for the current song once and shares them between the Lyrics widget and the
/// full Purr player. Keeps a small cache so skipping back and forth doesn't re-download.
public final class LyricsStore {

	public static let shared = LyricsStore()

	public enum Status: Equatable { case idle, nothingPlaying, searching, notASong, notFound, ready }

	public private(set) var status: Status = .idle
	private(set) var lyrics: Lyrics?
	public private(set) var trackKey: String?

	private var cache: [String: Lyrics?] = [:]
	private var cacheOrder: [String] = []
	private let cacheLimit = 24
	private var listeners: [UUID: () -> Void] = [:]

	private init() {}

	@discardableResult
	public func observe(_ handler: @escaping () -> Void) -> UUID {
		let id = UUID()
		listeners[id] = handler
		return id
	}

	public func removeObserver(_ id: UUID?) {
		guard let id else { return }
		listeners[id] = nil
	}

	private func notify() { listeners.values.forEach { $0() } }

	/// Human-readable status line for the Touch Bar.
	public var statusText: String {
		switch status {
		case .idle, .ready: return ""
		case .nothingPlaying: return "Nothing playing"
		case .searching: return "Searching lyrics…"
		case .notASong: return "No lyrics for this"
		case .notFound: return "No lyrics found for this song"
		}
	}

	/// Make sure lyrics for `state` are loaded (or loading). Cheap to call on every update.
	public func update(for state: NowPlaying) {
		guard state.hasContent else {
			if status != .nothingPlaying { trackKey = nil; lyrics = nil; status = .nothingPlaying; notify() }
			return
		}
		let key = state.trackKey + "|" + LyricsScript.current.rawValue
		guard key != trackKey else { return }
		trackKey = key
		lyrics = nil
		if let hit = cache[key], let found = hit {
			lyrics = found
			status = .ready
			notify()
			return
		}
		status = .searching
		notify()
		// Song details often arrive in two steps (title first, artist a moment later); let them settle.
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
			guard let self, self.trackKey == key else { return }
			let current = NowPlayingCenter.shared.state
			// No artist means a web page or clip, not a song: don't search.
			guard !current.artist.trimmingCharacters(in: .whitespaces).isEmpty else {
				self.status = .notASong
				self.notify()
				return
			}
			self.search(current, key: key, attempt: 1)
		}
	}

	private func search(_ song: NowPlaying, key: String, attempt: Int) {
		LyricsSource.fetch(title: NowPlayingCenter.cleanTitle(song.title), artist: song.artist, duration: song.duration) { [weak self] result in
			guard let self else { return }
			// Only real results are cached: a failed lookup (network blip, a request cut short by
			// switching albums) must not hide this song's lyrics for the rest of the session.
			if result != nil { self.store(result, for: key) }
			guard self.trackKey == key else { return }
			if result == nil, attempt < 2 {
				DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
					guard let self, self.trackKey == key else { return }
					self.search(NowPlayingCenter.shared.state, key: key, attempt: attempt + 1)
				}
				return
			}
			self.lyrics = result
			self.status = result == nil ? .notFound : .ready
			self.notify()
		}
	}

	/// Tap on "No lyrics found": try again now.
	public func retry() {
		guard status == .notFound || status == .notASong else { return }
		trackKey = nil
		update(for: NowPlayingCenter.shared.state)
	}

	/// Forget the current song so the next `update` searches again (e.g. after changing script).
	public func reload() {
		trackKey = nil
		cache.removeAll()
		cacheOrder.removeAll()
		update(for: NowPlayingCenter.shared.state)
	}

	private func store(_ value: Lyrics?, for key: String) {
		if cache[key] == nil { cacheOrder.append(key) }
		cache[key] = .some(value)
		while cacheOrder.count > cacheLimit {
			cache[cacheOrder.removeFirst()] = nil
		}
	}

	// MARK: Per-song timing nudge (shared with the player)

	static func offsetKey(_ s: NowPlaying) -> String { "\(s.title)|\(s.artist)" }

	public static func offset(for s: NowPlaying) -> Double {
		(UserDefaults.standard.dictionary(forKey: "lyricOffsets")?[offsetKey(s)] as? Double) ?? 0
	}

	// MARK: Line lookup for the compact widget

	/// (current line, lit UTF-16 count, next line) at time `t`, or nil when there are no lyrics.
	public func line(at t: Double, duration: Double) -> (current: String, lit: Int, next: String)? {
		guard let lyrics else { return nil }
		let (a, lit, next) = lyrics.at(t, duration: duration)
		return (a, lit, next)
	}

	public var isSynced: Bool { lyrics?.synced ?? false }
}
