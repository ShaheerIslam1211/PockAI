import AppKit
import PockKit

// MARK: - The ✨ button that sits in the Pock bar

/// Shows ✨ when text is selected anywhere. Tap → the Writing Tools options take over the Touch Bar.
/// Long press → open the full Writing Tools panel.
public final class WritingToolsTouchBarView: TouchView {

	private let gradient = CAGradientLayer()
	private let icon = NSImageView()
	private let label = NSTextField(labelWithString: "Writing Tools")
	private var token: UUID?
	private let expandedWidth: CGFloat = 132

	public init() {
		super.init(width: 132, collapsed: SharedSettings.onlyOnSelection)
		layer?.cornerRadius = 6
		layer?.masksToBounds = true
		gradient.colors = PAIColors.aiGradient.map { $0.withAlphaComponent(0.85).cgColor }
		gradient.startPoint = CGPoint(x: 0, y: 0.5)
		gradient.endPoint = CGPoint(x: 1, y: 0.5)
		layer?.addSublayer(gradient)
		icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Writing Tools")?
			.withSymbolConfiguration(.init(pointSize: 14, weight: .bold))
		icon.contentTintColor = .white
		addSubview(icon)
		label.font = .systemFont(ofSize: 13, weight: .semibold)
		label.textColor = .white
		addSubview(label)
		onTap = { WritingToolsBar.openForCurrentSelection() }
		onLongPress = { Task { @MainActor in await WritingToolsController.shared.show() } }
		NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: SharedSettings.didChange, object: nil)
	}

	required init?(coder: NSCoder) { super.init(coder: coder) }

	deinit {
		NotificationCenter.default.removeObserver(self)
		stop()
	}

	public func start() {
		guard token == nil else { return }
		if !SelectionBridge.isTrusted { SelectionBridge.requestTrust() }
		token = SelectionMonitor.shared.observe { [weak self] selected in self?.update(selected) }
	}

	public func stop() {
		SelectionMonitor.shared.removeObserver(token)
		token = nil
	}

	@objc private func settingsChanged() { update(SelectionMonitor.shared.hasSelection) }

	private func update(_ selected: Bool) {
		if SharedSettings.onlyOnSelection {
			setCollapsed(!selected)
		} else {
			setCollapsed(false)
			alphaValue = selected ? 1 : 0.55
		}
		if selected { pulse() }
	}

	private func pulse() {
		let anim = CABasicAnimation(keyPath: "transform.scale")
		anim.fromValue = 0.9
		anim.toValue = 1
		anim.duration = 0.25
		icon.layer?.add(anim, forKey: "pulse")
	}

	public override func layoutContent() {
		CATransaction.begin(); CATransaction.setDisableActions(true)
		gradient.frame = bounds
		CATransaction.commit()
		icon.frame = NSRect(x: 8, y: 5, width: 20, height: 20)
		label.frame = NSRect(x: 32, y: 6, width: max(0, bounds.width - 36), height: 18)
	}
}

// MARK: - Full-bar Writing Tools (options → working → result)

/// Writing Tools controlled entirely from the Touch Bar.
public final class WritingToolsBar: PKTouchBarController {

	private enum Stage { case options, working, result, replaced, error(String) }

	private static let closeId = NSTouchBarItem.Identifier("com.pockai.ai.close")
	private static let contentId = NSTouchBarItem.Identifier("com.pockai.ai.content")

	private var source = ""
	private var result = ""
	private var resultTitle = ""
	private var lastWork: (() async throws -> String)?
	private var lastMode: WritingMode?
	private weak var targetApp: NSRunningApplication?
	private var stage: Stage = .options
	private let container = NSView()
	private var task: Task<Void, Never>?
	private static weak var current: WritingToolsBar?

	private var contentWidth: CGFloat { TouchBarMetrics.fullBarContentWidth(reserving: 44) }

	// MARK: Entry point

	/// Reads the selection (Accessibility, or ⌘C as a fallback) and takes over the Touch Bar.
	public static func openForCurrentSelection() {
		let monitor = SelectionMonitor.shared
		let target = monitor.sourceApp ?? NSWorkspace.shared.frontmostApplication
		guard SelectionBridge.isTrusted else {
			SelectionBridge.requestTrust()
			Task { @MainActor in await WritingToolsController.shared.show() }
			return
		}
		Task { @MainActor in
			let text: String
			if let known = monitor.selectedText, !known.isEmpty {
				text = known
			} else {
				target?.activate()
				try? await Task.sleep(nanoseconds: 80_000_000)
				text = await SelectionBridge.readSelection() ?? ""
			}
			present(source: text, target: target)
		}
	}

	public static func present(source: String, target: NSRunningApplication?) {
		current?.dismiss()
		let bar = WritingToolsBar()
		bar.source = source
		bar.targetApp = target
		current = bar
		if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			bar.stage = .error("No text selected. Select some text, then tap ✨ again.")
		}
		if let nav = bar.mainNavigationController {
			// Replace any other full-bar screen instead of stacking on top of it (stacked ones were never freed).
			nav.popToRootController()
			nav.push(bar)
		} else {
			bar.present()
		}
		bar.render()
	}

	// MARK: Touch Bar

	public override func makeTouchBar() -> NSTouchBar? {
		let bar = NSTouchBar()
		bar.delegate = self
		bar.defaultItemIdentifiers = [Self.closeId, Self.contentId]
		return bar
	}

	public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
		let item = NSCustomTouchBarItem(identifier: identifier)
		switch identifier {
		case Self.closeId:
			let b = PAIButton(symbol: "xmark", target: self, action: #selector(close))
			b.bezelColor = PAIColors.chip
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
			item.view = b
		case Self.contentId:
			if container.constraints.isEmpty {
				container.wantsLayer = true
				container.translatesAutoresizingMaskIntoConstraints = false
				container.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
				container.heightAnchor.constraint(equalToConstant: 30).isActive = true
			}
			item.view = container
		default:
			return nil
		}
		return item
	}

	@objc private func close() {
		task?.cancel()
		dismiss()
	}

	public override func dismiss() {
		task?.cancel()
		super.dismiss()
		if Self.current === self { Self.current = nil }
	}

	// MARK: Rendering

	private func render() {
		NSLog("[PockAI] Writing Tools stage: \(stage)")
		container.subviews.forEach { $0.removeFromSuperview() }
		container.layer?.sublayers?.filter { $0.name == "glow" }.forEach { $0.removeFromSuperlayer() }
		let view: NSView
		switch stage {
		case .options: view = optionsView()
		case .working: view = workingView()
		case .result: view = resultView()
		case .replaced: view = replacedView()
		case .error(let message): view = errorView(message)
		}
		view.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 30)
		view.autoresizingMask = [.width, .height]
		container.addSubview(view)
		refreshPresentedBar()
	}

	/// Changing the views inside a bar that is already on screen doesn't always reach the Touch Bar
	/// process, so present a fresh NSTouchBar with the same items and retire the old one.
	private func refreshPresentedBar() {
		guard isVisible, let old = touchBar else { return }
		let fresh = makeTouchBar()
		touchBar = fresh
		if let fresh { SystemModalTouchBar.present(fresh, placement: 1) }
		SystemModalTouchBar.dismiss(old)
	}

	private func scroller(_ views: [NSView], spacing: CGFloat = 6) -> NSView {
		let stack = NSStackView(views: views)
		stack.orientation = .horizontal
		stack.spacing = spacing
		stack.alignment = .centerY
		stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
		let fitting = stack.fittingSize
		stack.frame = NSRect(x: 0, y: 0, width: max(fitting.width, contentWidth), height: 30)
		let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 30))
		scroll.hasHorizontalScroller = false
		scroll.hasVerticalScroller = false
		scroll.horizontalScrollElasticity = .allowed
		scroll.drawsBackground = false
		scroll.documentView = stack
		return scroll
	}

	/// Lays buttons out left to right with their real widths; returns the row and its width.
	private func buttonRow(_ views: [NSView], spacing: CGFloat = 6) -> (NSView, CGFloat) {
		let row = NSView()
		var x: CGFloat = 0
		for v in views {
			let w = max(44, ceil(v.intrinsicContentSize.width) + (v is NSButton ? 16 : 0))
			v.frame = NSRect(x: x, y: 0, width: w, height: 30)
			row.addSubview(v)
			x += w + spacing
		}
		let width = max(0, x - spacing)
		row.frame = NSRect(x: 0, y: 0, width: width, height: 30)
		return (row, width)
	}

	private func modeButton(_ mode: WritingMode) -> NSButton {
		let b = PAIButton(symbol: mode.symbol, title: mode.title, target: self, action: #selector(runMode(_:)))
		b.tag = WritingMode.allCases.firstIndex(of: mode) ?? 0
		b.bezelColor = mode.appliesDirectly ? NSColor(red: 0.32, green: 0.22, blue: 0.5, alpha: 1) : PAIColors.chip
		return b
	}

	private func optionsView() -> NSView {
		var views: [NSView] = []
		let spark = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!
			.withSymbolConfiguration(.init(pointSize: 14, weight: .bold))!)
		spark.contentTintColor = PAIColors.aiGradient[1]
		views.append(spark)
		views += SharedSettings.touchBarModes.map(modeButton)
		for (i, template) in SharedSettings.templates.enumerated() {
			let b = PAIButton(symbol: "wand.and.stars", title: template.title, target: self, action: #selector(runTemplate(_:)))
			b.tag = i
			b.bezelColor = NSColor(red: 0.35, green: 0.15, blue: 0.4, alpha: 1)
			views.append(b)
		}
		let more = PAIButton(symbol: "text.bubble", title: "Describe…", target: self, action: #selector(openPanel))
		views.append(more)
		return scroller(views)
	}

	private func label(_ text: String, size: CGFloat = 13, color: NSColor = .white) -> NSTextField {
		let l = NSTextField(labelWithString: text)
		l.font = .systemFont(ofSize: size, weight: .medium)
		l.textColor = color
		l.lineBreakMode = .byTruncatingTail
		return l
	}

	private func workingView() -> NSView {
		let v = NSView()
		v.wantsLayer = true
		let glow = CAGradientLayer()
		glow.name = "glow"
		let colors = PAIColors.aiGradient + [PAIColors.aiGradient[0]]
		glow.colors = colors.map { $0.withAlphaComponent(0.75).cgColor }
		glow.startPoint = CGPoint(x: 0, y: 0.5)
		glow.endPoint = CGPoint(x: 1, y: 0.5)
		glow.frame = NSRect(x: 0, y: 0, width: contentWidth * 2, height: 30)
		glow.cornerRadius = 6
		let slide = CABasicAnimation(keyPath: "position.x")
		slide.fromValue = 0
		slide.toValue = contentWidth
		slide.duration = 1.6
		slide.repeatCount = .infinity
		glow.add(slide, forKey: "slide")
		v.layer?.addSublayer(glow)
		v.layer?.cornerRadius = 6
		v.layer?.masksToBounds = true
		let title = label("✨ \(resultTitle)…  " + source.replacingOccurrences(of: "\n", with: " "), size: 13)
		title.frame = NSRect(x: 10, y: 6, width: contentWidth - 20, height: 18)
		v.addSubview(title)
		return v
	}

	private func resultView() -> NSView {
		var buttons: [NSView] = []
		if targetApp != nil {
			let replace = PAIButton(symbol: "checkmark", title: "Replace", target: self, action: #selector(replace))
			replace.bezelColor = .systemBlue
			buttons.append(replace)
		}
		buttons.append(PAIButton(symbol: "doc.on.doc", title: "Copy", target: self, action: #selector(copyResult)))
		buttons.append(PAIButton(symbol: "arrow.clockwise", title: nil, target: self, action: #selector(retry)))
		buttons.append(PAIButton(symbol: "macwindow", title: nil, target: self, action: #selector(openResultPanel)))
		buttons.append(PAIButton(symbol: "chevron.left", title: nil, target: self, action: #selector(back)))
		let (stack, buttonsWidth) = buttonRow(buttons)
		let v = NSView()
		v.addSubview(stack)
		// Result preview: swipe to read through it.
		let text = result.replacingOccurrences(of: "\n", with: "  ⏎  ")
		let preview = label(text, size: 13)
		preview.lineBreakMode = .byClipping
		preview.sizeToFit()
		let previewWidth = contentWidth - buttonsWidth - 10
		preview.frame = NSRect(x: 0, y: 6, width: max(preview.frame.width + 10, previewWidth), height: 18)
		let doc = NSView(frame: NSRect(x: 0, y: 0, width: preview.frame.width, height: 30))
		doc.addSubview(preview)
		let scroll = NSScrollView(frame: NSRect(x: buttonsWidth + 10, y: 0, width: previewWidth, height: 30))
		scroll.drawsBackground = true
		scroll.backgroundColor = NSColor(white: 0.14, alpha: 1)
		scroll.wantsLayer = true
		scroll.layer?.cornerRadius = 6
		scroll.hasHorizontalScroller = false
		scroll.documentView = doc
		v.addSubview(scroll)
		return v
	}

	private func replacedView() -> NSView {
		let done = label("✓  Replaced with \(resultTitle)", size: 13, color: .systemGreen)
		let undo = PAIButton(symbol: "arrow.uturn.backward", title: "Undo", target: self, action: #selector(undo))
		let ok = PAIButton(symbol: nil, title: "Done", target: self, action: #selector(close))
		return scroller([done, undo, ok], spacing: 10)
	}

	private func errorView(_ message: String) -> NSView {
		let text = label("⚠︎ " + message, size: 12, color: .systemOrange)
		var views: [NSView] = []
		if lastWork != nil { views.append(PAIButton(symbol: "arrow.clockwise", title: "Retry", target: self, action: #selector(retry))) }
		if !KeyStore.hasKey { views.append(PAIButton(symbol: "key", title: "Add API key", target: self, action: #selector(openSettings))) }
		views.append(PAIButton(symbol: "chevron.left", title: nil, target: self, action: #selector(back)))
		let (stack, w) = buttonRow(views)
		let v = NSView()
		text.frame = NSRect(x: 4, y: 6, width: contentWidth - w - 12, height: 18)
		stack.frame.origin.x = contentWidth - w
		v.addSubview(text)
		v.addSubview(stack)
		return v
	}

	// MARK: Actions

	/// Automation: run a mode (e.g. "fix") on the open Writing Tools bar.
	public static func runOnCurrent(modeNamed name: String) {
		guard let bar = current, let mode = WritingMode(rawValue: name) else { return }
		let button = NSButton()
		button.tag = WritingMode.allCases.firstIndex(of: mode) ?? 0
		bar.runMode(button)
	}

	@objc private func runMode(_ sender: NSButton) {
		let mode = WritingMode.allCases[min(max(0, sender.tag), WritingMode.allCases.count - 1)]
		lastMode = mode
		let text = source
		start(title: mode.progressTitle, resultTitle: mode.title) { try await GeminiClient.shared.run(mode, text: text) }
	}

	@objc private func runTemplate(_ sender: NSButton) {
		let templates = SharedSettings.templates
		guard templates.indices.contains(sender.tag) else { return }
		let template = templates[sender.tag]
		lastMode = nil
		let text = source
		start(title: template.title, resultTitle: template.title) { try await GeminiClient.shared.custom(template.instruction, text: text) }
	}

	private func start(title: String, resultTitle: String, _ work: @escaping () async throws -> String) {
		lastWork = work
		self.resultTitle = title
		stage = .working
		render()
		task?.cancel()
		task = Task { @MainActor [weak self] in
			do {
				let output = try await work()
				guard let self, !Task.isCancelled else { return }
				self.result = output
				self.resultTitle = resultTitle
				if SharedSettings.applyDirectly, self.lastMode?.appliesDirectly == true, self.targetApp != nil {
					self.replace()
				} else {
					self.stage = .result
					self.render()
				}
			} catch {
				guard let self, !Task.isCancelled else { return }
				self.stage = .error(error.localizedDescription)
				self.render()
			}
		}
	}

	@objc private func retry() {
		guard let work = lastWork else { return }
		start(title: resultTitle, resultTitle: resultTitle, work)
	}

	@objc private func back() {
		stage = .options
		render()
	}

	@objc private func replace() {
		let text = result
		let app = targetApp
		Task { @MainActor [weak self] in
			await SelectionBridge.replaceSelection(with: text, in: app)
			SelectionMonitor.shared.clear()
			guard let self else { return }
			self.stage = .replaced
			self.render()
			try? await Task.sleep(nanoseconds: 6_000_000_000)
			if case .replaced = self.stage { self.close() }
		}
	}

	@objc private func undo() {
		let app = targetApp
		Task { @MainActor [weak self] in
			await SelectionBridge.undo(in: app)
			self?.close()
		}
	}

	@objc private func copyResult() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(result, forType: .string)
		resultTitle = "Copied"
		stage = .replaced
		render()
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close() }
	}

	@objc private func openPanel() {
		let text = source
		close()
		Task { @MainActor in await WritingToolsController.shared.show(text: text) }
	}

	@objc private func openResultPanel() {
		let (s, r, t, app) = (source, result, resultTitle, targetApp)
		close()
		Task { @MainActor in WritingToolsController.shared.show(source: s, result: r, title: t, target: app) }
	}

	@objc private func openSettings() {
		close()
		PockAISettings.open(tab: .ai)
	}
}
