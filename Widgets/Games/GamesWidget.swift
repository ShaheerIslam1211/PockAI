import AppKit
import PockKit
import PockAIKit

/// 🎮 on the Pock bar → a game picker that takes over the whole Touch Bar.
final class GamesWidget: NSObject, PKWidget {
	static var identifier: String = "com.pockai.widget.Games"
	var customizationLabel: String = "Games"
	var view: NSView!

	required override init() {
		super.init()
		let b = PAIButton(symbol: "gamecontroller.fill", title: "Games", target: self, action: #selector(open))
		b.bezelColor = NSColor(red: 0.2, green: 0.45, blue: 0.3, alpha: 1)
		view = b
		// Automation / testing: open the picker, or a game by number ("0"…"3").
		NSLog("[PockAI] Games hook registered")
		observer = DistributedNotificationCenter.default().addObserver(forName: .init("local.pockai.games.open"), object: nil, queue: .main) { note in
			NSLog("[PockAI] Games hook fired: \(String(describing: note.object))")
			GamesBar.open(game: (note.object as? String).flatMap(Int.init))
		}
	}

	private var observer: NSObjectProtocol?
	deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }

	@objc private func open() { GamesBar.open(game: nil) }
}

// MARK: - Full-bar host

final class GamesBar: PKTouchBarController {
	private static let closeId = NSTouchBarItem.Identifier("com.pockai.games.close")
	private static let contentId = NSTouchBarItem.Identifier("com.pockai.games.content")
	private static weak var current: GamesBar?

	private let width = TouchBarMetrics.fullBarContentWidth(reserving: 44)
	private lazy var container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
	private var gameView: GameView?

	static func open(game: Int? = nil) {
		current?.dismiss()
		let bar = GamesBar()
		current = bar
		if let nav = bar.mainNavigationController {
			// Replace any other full-bar screen instead of stacking on top of it (stacked ones were never freed).
			nav.popToRootController()
			nav.push(bar)
		} else { bar.present() }
		if let game, (0...3).contains(game) {
			let b = NSButton()
			b.tag = game
			bar.pick(b)
		}
	}

	override func makeTouchBar() -> NSTouchBar? {
		let bar = NSTouchBar()
		bar.delegate = self
		bar.defaultItemIdentifiers = [Self.closeId, Self.contentId]
		return bar
	}

	@objc func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
		let item = NSCustomTouchBarItem(identifier: identifier)
		switch identifier {
		case Self.closeId:
			let b = PAIButton(symbol: "xmark", target: self, action: #selector(closeTapped))
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
			item.view = b
		case Self.contentId:
			if container.constraints.isEmpty {
				container.translatesAutoresizingMaskIntoConstraints = false
				container.widthAnchor.constraint(equalToConstant: width).isActive = true
				container.heightAnchor.constraint(equalToConstant: 30).isActive = true
			}
			// First build only: building content must never re-present the bar (that re-asks for this
			// item → endless loop). Later rebuilds keep whatever is in the container (picker or game).
			if container.subviews.isEmpty { showPicker(refresh: false) }
			item.view = container
		default:
			return nil
		}
		return item
	}

	private func showPicker(refresh: Bool = true) {
		stopGame()
		container.subviews.forEach { $0.removeFromSuperview() }
		let games: [(String, String, Int)] = [("🦖", "Dino Run", 0), ("🔨", "Whack-a-Mole", 1), ("🎯", "Perfect Stop", 2), ("🧠", "Memory", 3)]
		var x: CGFloat = 0
		for (emoji, name, tag) in games {
			let best = UserDefaults.standard.integer(forKey: "pockai.games.best.\(tag)")
			let b = PAIButton(symbol: nil, title: "\(emoji) \(name)" + (best > 0 ? "  ★\(best)" : ""), target: self, action: #selector(pick(_:)))
			b.tag = tag
			b.bezelColor = NSColor(white: 0.22, alpha: 1)
			let w = ceil(b.intrinsicContentSize.width) + 20
			b.frame = NSRect(x: x, y: 0, width: w, height: 30)
			container.addSubview(b)
			x += w + 8
		}
		if refresh { refreshPresentedBar() }
	}

	@objc fileprivate func pick(_ sender: NSButton) {
		container.subviews.forEach { $0.removeFromSuperview() }
		let game: Game
		switch sender.tag {
		case 0: game = RunnerGame()
		case 1: game = WhackGame()
		case 2: game = StopGame()
		default: game = MemoryGame()
		}
		let view = GameView(frame: NSRect(x: 0, y: 0, width: width, height: 30), game: game, tag: sender.tag)
		view.onExit = { [weak self] in self?.showPicker() }
		container.addSubview(view)
		gameView = view
		refreshPresentedBar()
		view.start()
	}

	private var refreshing = false

	/// Swapping views inside a presented bar needs a re-present to reach the Touch Bar.
	private func refreshPresentedBar() {
		guard isVisible, !refreshing, let old = touchBar else { return }
		refreshing = true
		defer { refreshing = false }
		let fresh = makeTouchBar()
		touchBar = fresh
		if let fresh { SystemModalTouchBar.present(fresh, placement: 1) }
		SystemModalTouchBar.dismiss(old)
	}

	private func stopGame() {
		gameView?.stop()
		gameView = nil
	}

	@objc private func closeTapped() {
		if gameView != nil { showPicker() } else { dismiss() }
	}

	override func dismiss() {
		stopGame()
		super.dismiss()
		if Self.current === self { Self.current = nil }
	}

	override func minimize() {
		gameView?.pause()
		super.minimize()
	}
}

// MARK: - Engine

protocol Game: AnyObject {
	var score: Int { get }
	var isOver: Bool { get }
	var hint: String { get }
	func reset(size: CGSize)
	func step(_ dt: Double, size: CGSize)
	func draw(in rect: CGRect)
	func touchDown(at x: CGFloat, size: CGSize)
}

/// Runs a game at 30 fps with a single redraw per frame (the Touch Bar shows plain redraws reliably).
final class GameView: NSView {
	var onExit: (() -> Void)?
	private let game: Game
	private let tag_: Int
	private var timer: Timer?
	private var last = CACurrentMediaTime()
	private var started = false
	private var recorded = false

	init(frame: NSRect, game: Game, tag: Int) {
		self.game = game
		self.tag_ = tag
		super.init(frame: frame)
		wantsLayer = true
		allowedTouchTypes = [.direct]
	}

	required init?(coder: NSCoder) { return nil }

	deinit { timer?.invalidate() }

	private var best: Int {
		get { UserDefaults.standard.integer(forKey: "pockai.games.best.\(tag_)") }
		set { UserDefaults.standard.set(newValue, forKey: "pockai.games.best.\(tag_)") }
	}

	func start() {
		game.reset(size: bounds.size)
		started = false
		recorded = false
		resume()
		needsDisplay = true
	}

	func resume() {
		timer?.invalidate()
		last = CACurrentMediaTime()
		let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.frame_() }
		RunLoop.main.add(t, forMode: .common)
		timer = t
	}

	func pause() { timer?.invalidate(); timer = nil }
	func stop() { pause() }

	private func frame_() {
		let now = CACurrentMediaTime()
		let dt = min(0.1, now - last)
		last = now
		if started && !game.isOver { game.step(dt, size: bounds.size) }
		if game.isOver && !recorded {
			recorded = true
			if game.score > best { best = game.score }
			if UserDefaults.standard.object(forKey: "pockai.games.sound") as? Bool ?? true { NSSound(named: "Bottle")?.play() }
		}
		needsDisplay = true
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.black.setFill()
		bounds.fill()
		game.draw(in: bounds)
		let hud = "\(game.score)  ★\(max(best, game.score))"
		let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
													 .foregroundColor: NSColor(white: 1, alpha: 0.75)]
		(hud as NSString).draw(at: NSPoint(x: bounds.width - (hud as NSString).size(withAttributes: attrs).width - 6, y: 9), withAttributes: attrs)
		if !started || game.isOver {
			let message = game.isOver ? "Game over · \(game.score) — tap to play again" : game.hint
			let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
			let size = (message as NSString).size(withAttributes: a)
			NSColor(white: 0, alpha: 0.65).setFill()
			NSBezierPath(roundedRect: NSRect(x: (bounds.width - size.width) / 2 - 10, y: 3, width: size.width + 20, height: 24), xRadius: 6, yRadius: 6).fill()
			(message as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 7), withAttributes: a)
		}
	}

	override func touchesBegan(with event: NSEvent) {
		guard let touch = event.touches(matching: .began, in: self).first else { return }
		let x = touch.location(in: self).x
		if game.isOver {
			start()
			return
		}
		if !started {
			started = true
			return
		}
		game.touchDown(at: x, size: bounds.size)
	}
}

private func emoji(_ s: String, size: CGFloat, at p: NSPoint) {
	(s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size)])
}

// MARK: Dino Run

final class RunnerGame: Game {
	private(set) var score = 0
	private(set) var isOver = false
	let hint = "🦖 Dino Run — tap to jump over the cacti. Tap to start"
	private var y: CGFloat = 0, vy: CGFloat = 0
	private var obstacles: [CGFloat] = []
	private var speed: CGFloat = 170
	private var distance: CGFloat = 0
	private var nextSpawn: CGFloat = 300
	private let playerX: CGFloat = 50

	func reset(size: CGSize) {
		score = 0; isOver = false; y = 0; vy = 0; obstacles = []; speed = 170; distance = 0; nextSpawn = 300
	}

	func step(_ dt: Double, size: CGSize) {
		let dt = CGFloat(dt)
		vy -= 900 * dt
		y = max(0, y + vy * dt)
		if y == 0 { vy = 0 }
		let dx = speed * dt
		distance += dx
		obstacles = obstacles.map { $0 - dx }.filter { $0 > -20 }
		nextSpawn -= dx
		if nextSpawn <= 0 {
			obstacles.append(size.width + 10)
			nextSpawn = CGFloat.random(in: 140...320) * (speed / 170)
		}
		speed = min(420, 170 + distance / 40)
		score = Int(distance / 25)
		for x in obstacles where abs(x - playerX) < 12 && y < 13 { isOver = true }
	}

	func draw(in rect: CGRect) {
		NSColor(white: 0.35, alpha: 1).setFill()
		NSRect(x: 0, y: 2, width: rect.width, height: 1).fill()
		for x in obstacles { emoji("🌵", size: 14, at: NSPoint(x: x - 8, y: 2)) }
		emoji("🦖", size: 16, at: NSPoint(x: playerX - 10, y: 2 + y))
	}

	func touchDown(at x: CGFloat, size: CGSize) {
		if y == 0 { vy = 300 }
	}
}

// MARK: Whack-a-Mole

final class WhackGame: Game {
	private(set) var score = 0
	private(set) var isOver = false
	let hint = "🔨 Whack-a-Mole — tap the 🐹, avoid 💣. 30 seconds. Tap to start"
	private struct Mole { var slot: Int; var ttl: Double; var bomb: Bool; var hit = false }
	private var moles: [Mole] = []
	private var timeLeft = 30.0
	private var spawn = 0.4
	private let slots = 12

	func reset(size: CGSize) { score = 0; isOver = false; moles = []; timeLeft = 30; spawn = 0.4 }

	private func slotWidth(_ size: CGSize) -> CGFloat { (size.width - 90) / CGFloat(slots) }

	func step(_ dt: Double, size: CGSize) {
		timeLeft -= dt
		if timeLeft <= 0 { isOver = true; return }
		for i in moles.indices { moles[i].ttl -= dt }
		moles.removeAll { $0.ttl <= 0 }
		spawn -= dt
		if spawn <= 0 {
			let free = (0..<slots).filter { s in !moles.contains { $0.slot == s } }
			if let slot = free.randomElement() {
				let fast = max(0.45, 1.1 - (30 - timeLeft) / 50)
				moles.append(Mole(slot: slot, ttl: fast, bomb: Double.random(in: 0...1) < 0.15))
			}
			spawn = max(0.22, 0.6 - (30 - timeLeft) / 80)
		}
	}

	func draw(in rect: CGRect) {
		let w = slotWidth(rect.size)
		for s in 0..<slots {
			NSColor(white: 0.16, alpha: 1).setFill()
			NSBezierPath(roundedRect: NSRect(x: CGFloat(s) * w + 3, y: 3, width: w - 6, height: 24), xRadius: 5, yRadius: 5).fill()
		}
		for m in moles {
			emoji(m.hit ? "💥" : (m.bomb ? "💣" : "🐹"), size: 16, at: NSPoint(x: CGFloat(m.slot) * w + w / 2 - 10, y: 5))
		}
		let t = String(format: "%.0fs", max(0, timeLeft))
		(t as NSString).draw(at: NSPoint(x: rect.width - 86, y: 9), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.systemOrange])
	}

	func touchDown(at x: CGFloat, size: CGSize) {
		let slot = Int(x / slotWidth(size))
		guard let i = moles.firstIndex(where: { $0.slot == slot && !$0.hit }) else { return }
		if moles[i].bomb {
			score = max(0, score - 3)
			if UserDefaults.standard.object(forKey: "pockai.games.sound") as? Bool ?? true { NSSound.beep() }
		} else { score += 1 }
		moles[i].hit = true
		moles[i].ttl = 0.15
	}
}

// MARK: Perfect Stop

final class StopGame: Game {
	private(set) var score = 0
	private(set) var isOver = false
	let hint = "🎯 Perfect Stop — tap when the marker is in the green zone. Tap to start"
	private var pos: CGFloat = 0, dir: CGFloat = 1, speed: CGFloat = 260
	private var zone: ClosedRange<CGFloat> = 0...1
	private var zoneWidth: CGFloat = 120
	private var flash = 0.0

	func reset(size: CGSize) {
		score = 0; isOver = false; pos = 10; dir = 1; speed = 260; zoneWidth = 120
		newZone(size)
	}

	private func newZone(_ size: CGSize) {
		let usable = size.width - 90
		let start = CGFloat.random(in: 20...(max(21, usable - zoneWidth - 20)))
		zone = start...(start + zoneWidth)
	}

	func step(_ dt: Double, size: CGSize) {
		let usable = size.width - 90
		pos += dir * speed * CGFloat(dt)
		if pos > usable { pos = usable; dir = -1 }
		if pos < 0 { pos = 0; dir = 1 }
		flash = max(0, flash - dt)
	}

	func draw(in rect: CGRect) {
		NSColor(white: 0.15, alpha: 1).setFill()
		NSRect(x: 0, y: 12, width: rect.width - 90, height: 6).fill()
		(flash > 0 ? NSColor.white : NSColor.systemGreen).withAlphaComponent(0.8).setFill()
		NSBezierPath(roundedRect: NSRect(x: zone.lowerBound, y: 6, width: zone.upperBound - zone.lowerBound, height: 18), xRadius: 4, yRadius: 4).fill()
		NSColor.systemYellow.setFill()
		NSBezierPath(roundedRect: NSRect(x: pos - 3, y: 2, width: 6, height: 26), xRadius: 3, yRadius: 3).fill()
	}

	func touchDown(at x: CGFloat, size: CGSize) {
		if zone.contains(pos) {
			score += 1
			flash = 0.15
			zoneWidth = max(18, zoneWidth * 0.88)
			speed = min(900, speed * 1.08)
			newZone(size)
		} else {
			isOver = true
		}
	}
}

// MARK: Memory (repeat the colours)

final class MemoryGame: Game {
	private(set) var score = 0
	private(set) var isOver = false
	let hint = "🧠 Memory — watch the colours, then tap them in the same order. Tap to start"
	private let colors: [NSColor] = [.systemRed, .systemGreen, .systemBlue, .systemYellow, .systemPurple]
	private var sequence: [Int] = []
	private var input = 0
	private var showing = true
	private var showIndex = 0
	private var showTimer = 0.0
	private var lit: Int?
	private var litTimer = 0.0

	func reset(size: CGSize) {
		score = 0; isOver = false; sequence = [Int.random(in: 0..<colors.count)]
		startShowing()
	}

	private func startShowing() {
		showing = true; showIndex = 0; showTimer = 0.6; input = 0; lit = nil
	}

	func step(_ dt: Double, size: CGSize) {
		litTimer -= dt
		if litTimer <= 0 { lit = nil }
		guard showing else { return }
		showTimer -= dt
		if showTimer <= 0 {
			if showIndex < sequence.count {
				lit = sequence[showIndex]
				litTimer = 0.45
				showIndex += 1
				showTimer = max(0.35, 0.7 - Double(sequence.count) * 0.02)
			} else {
				showing = false
			}
		}
	}

	private func padRect(_ i: Int, _ rect: CGRect) -> NSRect {
		let w = (rect.width - 90) / CGFloat(colors.count)
		return NSRect(x: CGFloat(i) * w + 4, y: 3, width: w - 8, height: 24)
	}

	func draw(in rect: CGRect) {
		for i in colors.indices {
			colors[i].withAlphaComponent(lit == i ? 1 : 0.28).setFill()
			NSBezierPath(roundedRect: padRect(i, rect), xRadius: 6, yRadius: 6).fill()
		}
		if showing {
			("watch…" as NSString).draw(at: NSPoint(x: rect.width - 86, y: 9), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.6)])
		}
	}

	func touchDown(at x: CGFloat, size: CGSize) {
		guard !showing else { return }
		let w = (size.width - 90) / CGFloat(colors.count)
		let pad = Int(x / w)
		guard colors.indices.contains(pad), sequence.indices.contains(input) else { return }
		lit = pad
		litTimer = 0.2
		if pad == sequence[input] {
			input += 1
			if input == sequence.count {
				score = sequence.count
				sequence.append(Int.random(in: 0..<colors.count))
				showTimer = 0.9
				showing = true
				showIndex = 0
				input = 0
			}
		} else {
			isOver = true
		}
	}
}
