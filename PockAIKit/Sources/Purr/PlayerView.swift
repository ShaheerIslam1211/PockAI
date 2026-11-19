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

// MARK: - Player view

final class PlayerView: NSView {
    static let compactTextW: CGFloat = 140
    var onCommand: ((Cmd) -> Void)?
    var onSeek: ((Double) -> Void)?

    private let gradient = CAGradientLayer()
    private let artLayer = CALayer()
    private let glow = CALayer()
    private let title = Marquee(font: .systemFont(ofSize: 12.5, weight: .semibold))
    private let artist = Marquee(font: .systemFont(ofSize: 10.5, weight: .medium))
    private let prev = NSButton()
    private let play = NSButton()
    private let next = NSButton()
    private let scrubber = Scrubber(frame: .zero)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainLabel = NSTextField(labelWithString: "-0:00")
    private let lyricNow = KaraokeLine(font: .systemFont(ofSize: 16, weight: .heavy))
    private let lyricTrans = KaraokeLine(font: .systemFont(ofSize: 10.5, weight: .medium))
    private var translationText = ""
    private let artBlur = CALayer()
    private let artDim = CALayer()
    let volume = VolumeView()
    var showsVolume = false { didSet { if showsVolume != oldValue { relayout() } } }

    private var palette = Palette.forApp(nil)
    private var basePalette = Palette.forApp(nil)
    var theme: Theme = .standard { didSet { applyTheme() } }
    private var style: ThemeStyle { theme.style }
    private let themeBg = CAGradientLayer()
    private let stripes = CAGradientLayer()
    private let scanLayer = CALayer()
    private let recordHole = CALayer()
    private var duration = 0.0
    private var position = 0.0
    private var lastScrub = Date.distantPast
    private var titleText = "", artistText = ""
    private(set) var lyricsMode = false
    private var lyricA = "", lyricLit = 0
    private var widthConstraint: NSLayoutConstraint?
    private(set) var currentWidth: CGFloat = 690

    override var intrinsicContentSize: NSSize { NSSize(width: currentWidth, height: 30) }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 690, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        widthConstraint = widthAnchor.constraint(equalToConstant: currentWidth)
        widthConstraint?.isActive = true

        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(gradient)
        artBlur.contentsGravity = .resizeAspectFill
        artBlur.opacity = 0.95
        artDim.backgroundColor = NSColor.black.cgColor
        artDim.opacity = 0.4
        artBlur.masksToBounds = true
        layer?.addSublayer(artBlur)
        layer?.addSublayer(artDim)
        themeBg.startPoint = CGPoint(x: 0, y: 0.5)
        themeBg.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(themeBg)
        stripes.colors = [0xe8742a, 0xe8742a, 0xc4441c, 0xc4441c, 0x6b2a14, 0x6b2a14].map { hex(UInt32($0)).cgColor }
        stripes.locations = [0, 0.33, 0.33, 0.66, 0.66, 1]
        stripes.startPoint = CGPoint(x: 0.5, y: 1)
        stripes.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(stripes)
        scanLayer.contents = ThemeArt.scanlines
        scanLayer.contentsGravity = .resize
        scanLayer.zPosition = 50
        recordHole.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        recordHole.cornerRadius = 2.5
        lyricNow.centered = true
        lyricTrans.centered = true
        pausedLine.centered = true
        for _ in 0..<(Self.barsPerSide * 2) {
            let b = CALayer()
            b.cornerRadius = 1.75
            dots.addSublayer(b)
            dotLayers.append(b)
        }
        refreshBarsArt()
        noteLayer.contentsGravity = .resizeAspect
        noteLayer.contentsScale = 2
        dots.addSublayer(noteLayer)
        dots.opacity = 0
        introCard.opacity = 0
        for l in [introTitle, introBy, introArtist] {
            l.contentsScale = 2
            l.contentsGravity = .resize
            introCard.addSublayer(l)
        }

        glow.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        glow.cornerRadius = 6
        layer?.addSublayer(glow)

        artLayer.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        artLayer.cornerRadius = 6
        artLayer.masksToBounds = true
        artLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(artLayer)
        artLayer.addSublayer(recordHole)
        recordHole.frame = CGRect(x: 12.5, y: 12.5, width: 5, height: 5)
        layer?.addSublayer(scanLayer)

        for l in [title.layer, artist.layer, lyricNow.layer, lyricTrans.layer, pausedLine.layer, dots, introCard] {
            layer?.addSublayer(l)
        }
        lyricNow.layer.isHidden = true
        lyricTrans.layer.isHidden = true
        pausedLine.layer.isHidden = true

        configure(prev, symbol: "backward.fill", size: 13, action: #selector(tapPrev))
        configure(play, symbol: "play.fill", size: 15, action: #selector(tapPlay))
        configure(next, symbol: "forward.fill", size: 13, action: #selector(tapNext))

        for l in [elapsedLabel, remainLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            l.textColor = NSColor.white.withAlphaComponent(0.85)
            addSubview(l)
        }
        elapsedLabel.alignment = .right
        remainLabel.alignment = .left
        addSubview(volume)
        scrubber.onScrub = { [weak self] v, final in self?.scrubbed(v, final: final) }
        scrubber.onTouch = { [weak self] in self?.lastScrub = Date() }
        addSubview(scrubber)

        setUpPeek()
        startDrift()
        applyPalette()
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Lyrics mode: [cover][name/artist] [lyric line] [elapsed / total][⏯]
    private var lyricLeft: CGFloat { 40 + Self.compactTextW + 14 }
    private var lyricRight: CGFloat { currentWidth - 40 - 6 - 88 }

    private var textWidth: CGFloat {
        lyricsMode ? Self.compactTextW : min(330, max(200, 220 + (currentWidth - 690) * 0.45))
    }

    // Everything is placed from the current width, which changes when the side menu opens or closes.
    private func relayout() {
        let w = currentWidth
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = CGRect(x: 0, y: 0, width: w, height: 30)
        artBlur.frame = CGRect(x: 0, y: 0, width: w, height: 30)
        artDim.frame = artBlur.frame
        themeBg.frame = artBlur.frame
        scanLayer.frame = artBlur.frame
        stripes.frame = CGRect(x: 0, y: 0, width: w, height: 4)
        CATransaction.commit()
        updateControlImages()
        volume.isHidden = lyricsMode || !showsVolume
        elapsedLabel.alignment = .right
        if lyricsMode {
            play.frame = NSRect(x: w - 40, y: 0, width: 36, height: 30)
            elapsedLabel.frame = NSRect(x: lyricRight + 4, y: 8, width: w - 40 - 6 - lyricRight - 4, height: 14)
        } else {
            let x0 = 40 + textWidth + 8
            prev.frame = NSRect(x: x0, y: 0, width: 34, height: 30)
            play.frame = NSRect(x: x0 + 36, y: 0, width: 36, height: 30)
            next.frame = NSRect(x: x0 + 74, y: 0, width: 34, height: 30)
            let px = x0 + 116
            let volW: CGFloat = showsVolume ? VolumeView.width + 14 : 0
            elapsedLabel.frame = NSRect(x: px, y: 8, width: 38, height: 14)
            scrubber.frame = NSRect(x: px + 38, y: 0, width: max(60, w - volW - px - 38 - 42), height: 30)
            remainLabel.frame = NSRect(x: w - volW - 42, y: 8, width: 42, height: 14)
            volume.frame = NSRect(x: w - VolumeView.width - 6, y: 0, width: VolumeView.width, height: 30)
        }
        title.reset(); artist.reset(); lyricNow.reset()
        setText(titleText, artistText)
        setLyrics(lyricA, lit: lyricLit, animate: false)
        setProgress(position, duration: duration, smooth: false)
    }

    func setWidth(_ w: CGFloat) {
        guard w != currentWidth else { return }
        currentWidth = w
        widthConstraint?.constant = w
        invalidateIntrinsicContentSize()
        relayout()
    }

    private func configure(_ b: NSButton, symbol: String, size: CGFloat, action: Selector) {
        b.bezelStyle = .rounded
        b.title = ""
        b.image = symbolImage(symbol, size)
        b.imagePosition = .imageOnly
        b.target = self; b.action = action
        addSubview(b)
    }

    // Plain white skip icons and a small round play/pause in the song colour, in both views.
    private func updateControlImages() {
        let sym = isPlaying ? "pause.fill" : "play.fill"
        for (b, name) in [(prev, "backward.fill"), (next, "forward.fill")] {
            b.isBordered = false
            b.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [style.text])))
            b.contentTintColor = nil
        }
        play.isBordered = false
        play.contentTintColor = nil
        play.image = circleImage(sym)
    }

    private func circleImage(_ symbol: String) -> NSImage {
        let d: CGFloat = 26
        let kind = style.play
        let fill = kind == .white ? NSColor.white : palette.accent
        let glyphColor = kind == .white ? NSColor.black : kind == .outline ? palette.accent : palette.onAccent
        return NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            if kind == .outline {
                fill.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 2
                ring.stroke()
            } else {
                fill.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [glyphColor]))
            if let g = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let sz = g.size
                let nudge: CGFloat = symbol == "play.fill" ? 1 : 0
                g.draw(in: NSRect(x: (d - sz.width) / 2 + nudge, y: (d - sz.height) / 2, width: sz.width, height: sz.height))
            }
            return true
        }
    }

    private func symbolImage(_ name: String, _ size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold))
    }

    @objc private func tapPrev() { scrubber.expand(); onCommand?(.previous) }
    @objc private func tapNext() { scrubber.expand(); onCommand?(.next) }
    @objc private func tapPlay() { scrubber.expand(); onCommand?(.toggle) }

    private func scrubbed(_ v: Double, final: Bool) {
        guard duration > 0 else { return }
        lastScrub = Date()
        let t = v * duration
        elapsedLabel.stringValue = fmt(t)
        remainLabel.stringValue = "-" + fmt(duration - t)
        if final { onSeek?(t) }
    }

    func setPalette(_ p: Palette) {
        let newSong = !p.accent.isEqual(basePalette.accent)
        basePalette = p
        palette = style.accent.map(Palette.make) ?? p
        if newSong && style.accent == nil { blendControls() }
        applyPalette()
    }

    // New song colours: buttons, progress bar, volume and labels fade into their new colours with the backdrop.
    private func blendControls() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.6
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for v in [play, prev, next, scrubber, volume, elapsedLabel, remainLabel] as [NSView] { v.layer?.add(fade, forKey: "blend") }
        artist.layer.add(fade, forKey: "blend")
    }

    // Everything a theme changes: backdrop, corner, cover shape, fonts, colours, progress look.
    private func applyTheme() {
        let st = style
        palette = st.accent.map(Palette.make) ?? basePalette
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let usesArt: Bool
        switch st.background {
        case .art, .artBright: usesArt = true
        default: usesArt = false
        }
        artBlur.isHidden = !usesArt
        artDim.isHidden = !usesArt
        themeBg.isHidden = usesArt
        themeBg.contents = nil
        switch st.background {
        case .solid(let c): themeBg.colors = [c.cgColor, c.cgColor]
        case .gradient(let cs): themeBg.colors = cs.map(\.cgColor)
        case .cream: themeBg.colors = [hex(0xefe4cc).cgColor, hex(0xe6d8bb).cgColor]
        case .wood: themeBg.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]; themeBg.contents = ThemeArt.wood; themeBg.contentsGravity = .resize
        default: break
        }
        artBlur.opacity = isBright(st) ? 1 : 0.95
        artDim.opacity = min(0.92, baseDim * (isBright(st) ? 0.55 : 1) + (night ? 0.2 : 0))
        stripes.isHidden = !st.stripes
        scanLayer.isHidden = !st.scanlines
        layer?.cornerRadius = st.corner
        switch st.artShape {
        case .rounded: artLayer.cornerRadius = 6; artLayer.borderWidth = 0
        case .circle: artLayer.cornerRadius = 15; artLayer.borderWidth = 0
        case .record: artLayer.cornerRadius = 15; artLayer.borderWidth = 3; artLayer.borderColor = NSColor(white: 0.07, alpha: 1).cgColor
        }
        recordHole.isHidden = st.artShape != .record
        glow.isHidden = st.artShape != .rounded
        for (l, on) in [(title.textLayer, st.glow), (lyricNow.textLayer, st.glow)] {
            l.shadowColor = palette.accent.cgColor
            l.shadowRadius = 4
            l.shadowOffset = .zero
            l.shadowOpacity = on ? 0.9 : 0
        }
        CATransaction.commit()
        title.font = st.font(12.5, .semibold)
        artist.font = st.font(10.5, .medium)
        lyricNow.font = st.font(16, .heavy)
        for l in [elapsedLabel, remainLabel] {
            l.font = st.family == .mono ? .monospacedSystemFont(ofSize: 10, weight: .medium) : .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            l.textColor = st.text.withAlphaComponent(0.85)
        }
        scrubber.style = st.progress
        scrubber.dimColor = st.text.withAlphaComponent(0.22)
        volume.tint = st.text
        volume.sliderStyle = st.progress
        refreshBarsArt()
        startDrift()
        title.reset(); artist.reset(); lyricNow.reset()
        applyPalette()
        relayout()
        updateRecordSpin()
    }

    private func isBright(_ st: ThemeStyle) -> Bool {
        if case .artBright = st.background { return true }
        return false
    }

    private func updateRecordSpin() {
        if style.artShape == .record && isPlaying && !calm {
            if artLayer.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = -Double.pi * 2
                spin.duration = 3.2
                spin.repeatCount = .infinity
                artLayer.add(spin, forKey: "spin")
            }
        } else {
            artLayer.removeAnimation(forKey: "spin")
        }
    }

    private func applyPalette() {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.6)
        gradient.colors = [palette.deep.cgColor, palette.second.withAlphaComponent(0.55).cgColor, NSColor.black.cgColor]
        gradient.locations = [0, 0.45, 1]
        glow.shadowColor = palette.accent.cgColor
        glow.shadowOpacity = 0.9
        glow.shadowRadius = 6
        glow.shadowOffset = .zero
        glow.backgroundColor = NSColor.black.cgColor
        CATransaction.commit()
        play.bezelColor = palette.accent
        updateControlImages()
        for b in [prev, next] {
            b.bezelColor = palette.accent.withAlphaComponent(0.38)
            b.contentTintColor = style.text
        }
        scrubber.accent = palette.accent
        volume.accent = palette.accent
        setText(titleText, artistText)
    }

    private var artID: ObjectIdentifier?

    func setArt(_ img: NSImage?) {
        let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.begin(); CATransaction.setAnimationDuration(0.4)
        artLayer.contents = cg
        // Blurred copy of the cover as the backdrop; only redone when the cover changes.
        let id = img.map(ObjectIdentifier.init)
        if id != artID {
            if artID != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.8
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for l in [artLayer, artBlur, artDim] { l.add(fade, forKey: "songChange") }
            }
            artID = id
            var luminance: CGFloat = 0.3
            artBlur.contents = cg.flatMap { c -> CGImage? in
                let ci = CIImage(cgImage: c)
                let out = ci.clampedToExtent().applyingGaussianBlur(sigma: 14)
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
                let ctx = CIContext()
                var px = [UInt8](repeating: 0, count: 4)
                if let one = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    one.interpolationQuality = .medium
                    one.draw(c, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    luminance = (0.299 * CGFloat(px[0]) + 0.587 * CGFloat(px[1]) + 0.114 * CGFloat(px[2])) / 255
                }
                return ctx.createCGImage(out, from: ci.extent)
            }
            // Bright covers (white sleeves) get dimmed harder so white text and icons stay readable.
            baseDim = Float(max(0.35, min(0.85, 1 - 0.14 / max(luminance, 0.01))))
            artDim.opacity = min(0.92, baseDim * (isBright(style) ? 0.55 : 1) + (night ? 0.2 : 0))
        }
        CATransaction.commit()
    }

    func setText(_ t: String, _ a: String) {
        // New song: the name and artist slide in from the right.
        if !titleText.isEmpty && t != titleText && !lyricsMode {
            let slide = CATransition()
            slide.type = .push
            slide.subtype = .fromRight
            slide.duration = 0.45
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            title.layer.add(slide, forKey: "songChange")
            artist.layer.add(slide, forKey: "songChange")
        }
        titleText = t; artistText = a
        let st = style
        title.set(st.uppercase ? t.uppercased() : t, color: st.text, frame: CGRect(x: 40, y: 14, width: textWidth, height: 16))
        artist.set(st.uppercase ? a.uppercased() : a, color: st.sub ?? (palette.accent.blended(withFraction: 0.35, of: .white) ?? palette.accent),
                   frame: CGRect(x: 40, y: 1, width: textWidth, height: 14))
    }

    // Lyrics mode: song info shrinks behind a divider; the lyric lines take the rest of the bar.
    func setLyricsMode(_ on: Bool) {
        lyricsMode = on
        setCornerLabels(visible: !on || center != .intro, duration: 0)
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.25
        layer?.add(fade, forKey: "mode")
        for v in [scrubber, prev, next, remainLabel] as [NSView] { v.isHidden = on }
        updateLyricVisibility()
        relayout()
    }

    // A softly pulsing status ("Paused", "Finding lyrics…") stands in for the lyric line when there is nothing to sing along to.
    private let pausedLine = KaraokeLine(font: .systemFont(ofSize: 16, weight: .heavy))
    private var showingPaused = false
    private let dots = CALayer()
    private let noteLayer = CALayer()
    private var dotLayers: [CALayer] = []
    private var overlayText = ""
    private var overlayLit = 0

    // `visible` hides trailing characters without changing the width, so animated dots don't shift the centred text.
    func setOverlay(_ text: String?, visible: Int? = nil) {
        if let text {
            let lit = visible ?? (text as NSString).length
            if text != overlayText || lit != overlayLit {
                overlayText = text
                overlayLit = lit
                pausedLine.set(text, lit: lit, litColor: style.text, dimColor: .clear,
                               frame: CGRect(x: lyricLeft, y: 0, width: lyricRight - lyricLeft, height: 30))
            }
        }
        let on = text != nil
        guard on != showingPaused else { return }
        showingPaused = on
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.3
        lyricNow.layer.add(fade, forKey: "pause")
        lyricTrans.layer.add(fade, forKey: "pause")
        pausedLine.layer.add(fade, forKey: "pause")
        updateLyricVisibility()
        if on {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 1.2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if !calm { pausedLine.layer.add(pulse, forKey: "pulse") }
        } else {
            pausedLine.layer.removeAnimation(forKey: "pulse")
        }
    }

    private func updateLyricVisibility() {
        lyricNow.layer.isHidden = !lyricsMode || showingPaused
        lyricTrans.layer.isHidden = !lyricsMode || showingPaused
        pausedLine.layer.isHidden = !lyricsMode || !showingPaused
        dots.isHidden = !lyricsMode || showingPaused
        introCard.isHidden = !lyricsMode || showingPaused
    }

    // ♪ always sits between the bars; songs without lyrics also get a quiet "No lyrics" badge beside them,
    // so a no-lyrics song reads differently from a music break.
    private let noLyricsBadge = CALayer()

    enum Badge { case none, searching, noLyrics }
    private var badge = Badge.none
    private var badgeImages: [Badge: (CGImage?, CGSize)] = [:]

    private func badgeImage(_ text: String, _ symbol: String) -> (CGImage?, CGSize) {
        let colour = style.text.withAlphaComponent(0.6)
        let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: colour])
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [colour])))
        let iw = icon?.size.width ?? 0, lw = ceil(label.size().width)
        let size = NSSize(width: iw + 5 + lw, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: (16 - (icon?.size.height ?? 0)) / 2, width: iw, height: icon?.size.height ?? 0))
            label.draw(at: NSPoint(x: iw + 5, y: (16 - label.size().height) / 2))
            return true
        }
        return (img.cgImage(forProposedRect: nil, context: nil, hints: nil), size)
    }

    // Rebuilds the note and badge images in the current theme's colours.
    func refreshBarsArt() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold).applying(.init(paletteColors: [style.text]))
        noteLayer.contents = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)?.layerContents(forContentsScale: 2)
        badgeImages = [.searching: badgeImage("Finding lyrics", "magnifyingglass"), .noLyrics: badgeImage("No lyrics", "text.badge.xmark")]
        if noLyricsBadge.superlayer == nil {
            noLyricsBadge.contentsGravity = .resizeAspect
            noLyricsBadge.contentsScale = 2
            dots.addSublayer(noLyricsBadge)
        }
        let current = badge
        badge = .none
        setBadge(current)
    }

    // Small label beside the equaliser: "Finding lyrics" (gently pulsing) while searching, "No lyrics" when none exist.
    func setBadge(_ b: Badge) {
        guard b != badge else { return }
        badge = b
        CATransaction.begin(); CATransaction.setAnimationDuration(0.3)
        if let (img, size) = badgeImages[b] {
            noLyricsBadge.contents = img
            noLyricsBadge.bounds = CGRect(origin: .zero, size: size)
            noLyricsBadge.position = CGPoint(x: barsWidth + 18 + size.width / 2, y: 15)
            noLyricsBadge.opacity = 1
        } else {
            noLyricsBadge.opacity = 0
        }
        CATransaction.commit()
        noLyricsBadge.removeAnimation(forKey: "search")
        if b == .searching && !calm {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            noLyricsBadge.add(pulse, forKey: "search")
        }
    }

    private var barsWidth: CGFloat {
        let n = CGFloat(Self.barsPerSide)
        return (n * 3.5 + (n - 1) * 5) * 2 + 34
    }

    // ---- Living background: the blurred cover drifts and slowly zooms behind everything.

    private func startDrift() {
        artBlur.removeAnimation(forKey: "drift")
        guard !calm else { return }
        let drift = CAKeyframeAnimation(keyPath: "contentsRect")
        drift.values = [
            NSValue(rect: NSRect(x: 0.00, y: 0.20, width: 1.0, height: 0.60)),
            NSValue(rect: NSRect(x: 0.06, y: 0.45, width: 0.88, height: 0.45)),
            NSValue(rect: NSRect(x: 0.00, y: 0.05, width: 0.92, height: 0.55)),
            NSValue(rect: NSRect(x: 0.04, y: 0.30, width: 0.96, height: 0.50)),
            NSValue(rect: NSRect(x: 0.00, y: 0.20, width: 1.0, height: 0.60)),
        ]
        drift.duration = 36
        drift.repeatCount = .infinity
        drift.calculationMode = .cubic
        artBlur.add(drift, forKey: "drift")
    }

    // ---- Cover peek: tap the cover and the album art fills the bar, slowly panning; tap again or wait to return.

    private let peekLayer = CALayer()
    private let peekButton = NSButton()
    private let coverButton = NSButton()
    private var peekGeneration = 0

    private func setUpPeek() {
        coverButton.isBordered = false
        coverButton.title = ""
        coverButton.target = self
        coverButton.action = #selector(togglePeek)
        coverButton.frame = NSRect(x: 0, y: 0, width: 34, height: 30)
        addSubview(coverButton)
        peekButton.isBordered = false
        peekButton.title = ""
        peekButton.target = self
        peekButton.action = #selector(togglePeek)
        peekButton.isHidden = true
        addSubview(peekButton)
        peekLayer.contentsGravity = .resizeAspectFill
        peekLayer.masksToBounds = true
        peekLayer.opacity = 0
        peekLayer.zPosition = 60
        layer?.addSublayer(peekLayer)
    }

    @objc func togglePeek() {
        if peekButton.isHidden { showPeek() } else { hidePeek() }
    }

    private func showPeek() {
        guard let art = artLayer.contents else { return }
        peekGeneration += 1
        let generation = peekGeneration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        peekLayer.frame = CGRect(x: 0, y: 0, width: currentWidth, height: 30)
        peekLayer.contents = art
        CATransaction.commit()
        peekButton.frame = bounds
        peekButton.isHidden = false
        let pan = CABasicAnimation(keyPath: "contentsRect")
        pan.fromValue = NSValue(rect: NSRect(x: 0, y: 0.62, width: 1, height: 0.38))
        pan.toValue = NSValue(rect: NSRect(x: 0, y: 0.0, width: 1, height: 0.38))
        pan.duration = 6
        pan.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pan.fillMode = .forwards
        pan.isRemovedOnCompletion = false
        peekLayer.add(pan, forKey: "pan")
        CATransaction.begin(); CATransaction.setAnimationDuration(0.35)
        peekLayer.opacity = 1
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.peekGeneration == generation else { return }
            self.hidePeek()
        }
    }

    private func hidePeek() {
        peekGeneration += 1
        peekButton.isHidden = true
        CATransaction.begin(); CATransaction.setAnimationDuration(0.35)
        CATransaction.setCompletionBlock { [weak self] in self?.peekLayer.removeAnimation(forKey: "pan") }
        peekLayer.opacity = 0
        CATransaction.commit()
    }

    // Music-only stretch (intro, instrumental break): bouncing equaliser bars in the song colour.
    // Decorative: the app can't hear the audio, so the bars only show that music is playing.
    private static let barsPerSide = 18

    private var suppressPushUntil = Date.distantPast
    private var barsFrame = CGRect.null
    private var gapGeneration = 0
    var useRealLevels = false
    var onGapVisible: ((Bool) -> Void)?
    private var baseDim: Float = 0.4

    // Night mode: whole player dimmed, darker backdrop, and the same calmer motion as the battery saver.
    var night = false {
        didSet {
            guard night != oldValue else { return }
            CATransaction.begin(); CATransaction.setAnimationDuration(1.0)
            artDim.opacity = min(0.92, baseDim * (isBright(style) ? 0.55 : 1) + (night ? 0.2 : 0))
            CATransaction.commit()
            NSAnimationContext.runAnimationGroup { $0.duration = 1.0; animator().alphaValue = night ? 0.72 : 1 }
            calmChanged()
        }
    }

    private var calm: Bool { lowPower || night }

    private func calmChanged() {
        startDrift()
        updateRecordSpin()
        if center == .bars { startBars() }
        if calm { pausedLine.layer.removeAnimation(forKey: "pulse") }
    }

    // Battery saver: fewer, slower animations (no pulsing note or "Paused", slower canned bars).
    var lowPower = false {
        didSet {
            guard lowPower != oldValue else { return }
            calmChanged()
        }
    }

    // Crossfade both ways: the lyric fades out as the bars fade in, and back again when singing resumes.
    enum Center { case lyric, bars, intro }
    private var center = Center.lyric

    // What fills the middle of lyrics view; every switch is a crossfade.
    func setCenter(_ c: Center) {
        guard c != center else { return }
        let old = center
        center = c
        gapGeneration += 1
        let generation = gapGeneration
        if c == .bars {
            onGapVisible?(true)
            startBars()
        }
        if c == .intro {
            animateIntroIn()
            setCornerLabels(visible: false, duration: 0.3)
        }
        if old == .intro { flyIntroToCorner() }
        if c == .lyric { suppressPushUntil = Date().addingTimeInterval(1) }
        CATransaction.begin()
        CATransaction.setAnimationDuration(c == .lyric ? 0.7 : 0.5)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, old == .bars, self.gapGeneration == generation else { return }
            self.stopBars()
            self.onGapVisible?(false)
        }
        dots.opacity = c == .bars ? 1 : 0
        lyricNow.layer.opacity = c == .lyric ? 1 : 0
        lyricTrans.layer.opacity = c == .lyric ? 1 : 0
        if c == .intro { introCard.opacity = 1 }
        CATransaction.commit()
    }

    private func setCornerLabels(visible: Bool, duration: Double) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        title.layer.opacity = visible ? 1 : 0
        artist.layer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    // Song name glides into its spot beside the cover first, the artist follows; "by" fades away.
    private func flyIntroToCorner() {
        guard let root = layer, introTitle.contents != nil else { return }
        let plan: [(CALayer, CGFloat, CGFloat, Double)] = [
            (introTitle, 22, 12.5 / 15, 0),
            (introArtist, 8, 10.5 / 13, 0.28),
        ]
        var flyers: [CALayer] = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let byCopy = CALayer()
        byCopy.contents = introBy.contents
        byCopy.contentsScale = 2
        byCopy.contentsGravity = .resize
        byCopy.frame = root.convert(introBy.frame, from: introCard)
        root.addSublayer(byCopy)
        flyers.append(byCopy)
        introCard.opacity = 0
        CATransaction.commit()

        let fadeBy = CABasicAnimation(keyPath: "opacity")
        fadeBy.fromValue = 1
        fadeBy.toValue = 0
        fadeBy.duration = 0.25
        byCopy.opacity = 0
        byCopy.add(fadeBy, forKey: "fade")

        let timing = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        let now = root.convertTime(CACurrentMediaTime(), from: nil)
        for (source, centreY, scale, delay) in plan {
            let f = CALayer()
            f.contents = source.contents
            f.contentsScale = 2
            f.contentsGravity = .resize
            CATransaction.begin(); CATransaction.setDisableActions(true)
            f.frame = root.convert(source.frame, from: introCard)
            let fromPos = f.position, fromBounds = f.bounds
            let w = f.frame.width * scale, h = f.frame.height * scale
            f.frame = CGRect(x: 40, y: centreY - h / 2, width: w, height: h)
            root.addSublayer(f)
            CATransaction.commit()
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: fromPos)
            move.toValue = NSValue(point: f.position)
            let size = CABasicAnimation(keyPath: "bounds")
            size.fromValue = NSValue(rect: fromBounds)
            size.toValue = NSValue(rect: f.bounds)
            let group = CAAnimationGroup()
            group.animations = [move, size]
            group.duration = 0.55
            group.beginTime = now + delay
            group.fillMode = .backwards
            group.timingFunction = timing
            f.add(group, forKey: "fly")
            flyers.append(f)
        }
        // After the artist lands: real labels appear underneath at once, the copies fade off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            if self.center != .intro { self.setCornerLabels(visible: true, duration: 0) }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
            CATransaction.setCompletionBlock { flyers.forEach { $0.removeFromSuperlayer() } }
            flyers.forEach { $0.opacity = 0 }
            CATransaction.commit()
        }
    }

    // Intro card: one centred line. The song name appears alone, then "by Artist" slides in after it
    // while the name eases left so the whole line stays centred.
    private let introCard = CALayer()
    private let introTitle = CALayer()
    private let introBy = CALayer()
    private let introArtist = CALayer()
    private var introKey = ""
    private var introShownFor = ""

    // Text drawn on a shared baseline so the three pieces line up even at different sizes.
    private func textImage(_ s: String, _ font: NSFont, _ color: NSColor) -> (CGImage?, CGSize) {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        let w = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 2, h: CGFloat = 24, scale: CGFloat = 2
        guard w > 2, let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, .zero) }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textPosition = CGPoint(x: 0, y: 7)
        CTLineDraw(line, ctx)
        return (ctx.makeImage(), CGSize(width: w, height: h))
    }

    private var introAloneX: CGFloat = 0

    func setIntroText(_ title: String, _ artist: String) {
        let width = lyricRight - lyricLeft
        let tint = palette.accent.blended(withFraction: 0.35, of: .white) ?? palette.accent
        let key = "\(title)|\(artist)|\(width)|\(tint)|\(theme.rawValue)"
        let isNewSong = !introShownFor.isEmpty && title != introShownFor
        introShownFor = title
        guard key != introKey else { return }
        introKey = key
        let st = style
        let (ti, ts) = textImage(st.uppercase ? title.uppercased() : title, st.font(15, .heavy), st.text)
        let (bi, bs) = textImage(st.uppercase ? "BY" : "by", st.font(12, .medium), st.text.withAlphaComponent(0.65))
        let (ai, asz) = textImage(st.uppercase ? artist.uppercased() : artist, st.font(13, .semibold), st.sub ?? tint)
        let hasArtist = !artist.isEmpty
        var total = ts.width + (hasArtist ? 6 + bs.width + 5 + asz.width : 0)
        let k = min(1, width / max(total, 1))
        total *= k
        let x0 = (width - total) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        introCard.frame = CGRect(x: lyricLeft, y: 0, width: width, height: 30)
        introTitle.contents = ti
        introBy.contents = hasArtist ? bi : nil
        introArtist.contents = hasArtist ? ai : nil
        introTitle.frame = CGRect(x: x0, y: 3, width: ts.width * k, height: ts.height * k)
        introBy.frame = CGRect(x: introTitle.frame.maxX + 6 * k, y: 3, width: bs.width * k, height: bs.height * k)
        introArtist.frame = CGRect(x: introBy.frame.maxX + 5 * k, y: 3, width: asz.width * k, height: asz.height * k)
        introAloneX = (width - ts.width * k) / 2 + ts.width * k / 2
        CATransaction.commit()
        if center == .intro && isNewSong { animateIntroIn() }
    }

    private func animateIntroIn() {
        let now = CACurrentMediaTime()
        let ease = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        // Name: rises in centred on its own, holds, then eases left to make room.
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -6
        rise.toValue = 0
        rise.duration = 0.5
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.5
        let shift = CAKeyframeAnimation(keyPath: "position.x")
        shift.values = [introAloneX, introAloneX, introTitle.position.x]
        shift.keyTimes = [0, 0.6, 1]
        shift.duration = 1.5
        shift.timingFunctions = [CAMediaTimingFunction(name: .linear), ease]
        let nameGroup = CAAnimationGroup()
        nameGroup.animations = [rise, appear, shift]
        nameGroup.duration = 1.5
        nameGroup.beginTime = now
        introTitle.add(nameGroup, forKey: "intro")
        // "by Artist": slides in from the right once the name has made room.
        for l in [introBy, introArtist] {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 14
            slide.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let g = CAAnimationGroup()
            g.animations = [slide, fade]
            g.duration = 0.45
            g.beginTime = now + 1.3
            g.fillMode = .backwards
            g.timingFunction = ease
            l.add(g, forKey: "intro")
        }
    }

    func useFakeBars() {
        useRealLevels = false
        if center == .bars { startBars() }
    }

    // Real levels from AudioSpectrum: bass next to the note, treble towards the ends, mirrored.
    // Heights set directly, no implicit animations: at 24 updates a second it still reads smoothly,
    // and it avoids creating 36 animations (or uploading an image) every frame.
    func setLevels(_ levels: [Float]) {
        guard center == .bars, useRealLevels, !levels.isEmpty else { return }
        let n = Self.barsPerSide
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, b) in dotLayers.enumerated() {
            let fromCentre = i < n ? n - 1 - i : i - n
            let level = CGFloat(levels[min(fromCentre, levels.count - 1)])
            b.transform = CATransform3DMakeScale(1, 0.12 + 0.88 * level, 1)
        }
        CATransaction.commit()
    }

    private func startBars() {
        for (i, b) in dotLayers.enumerated() {
            b.removeAnimation(forKey: "bounce")
            b.backgroundColor = (i % 2 == 0 ? palette.accent : palette.accent.blended(withFraction: 0.4, of: .white) ?? palette.accent).cgColor
            if useRealLevels {
                b.transform = CATransform3DMakeScale(1, 0.12, 1)
                continue
            }
            b.transform = CATransform3DIdentity
            let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
            let seed = Double((i * 37 + 5) % 13) / 13
            bounce.values = [0.38, 0.65 + seed * 0.35, 0.45, 0.95 - seed * 0.25, 0.38]
            bounce.duration = (0.75 + seed * 0.5) * (calm ? 1.8 : 1)
            bounce.repeatCount = .infinity
            bounce.timeOffset = seed * bounce.duration
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            b.add(bounce, forKey: "bounce")
        }
        noteLayer.removeAnimation(forKey: "pulse")
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.88
        pulse.toValue = 1.12
        pulse.duration = 0.55
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if !calm { noteLayer.add(pulse, forKey: "pulse") }
    }

    private func stopBars() {
        for b in dotLayers {
            b.removeAnimation(forKey: "bounce")
            b.transform = CATransform3DIdentity
        }
        noteLayer.removeAnimation(forKey: "pulse")
    }

    // One big centred line: sung words bright, the rest dim; new lines rise in from below.
    func setLyrics(_ a: String, lit: Int, translation: String? = nil, animate: Bool = true) {
        let changed = a != lyricA
        lyricA = a; lyricLit = lit
        if let translation { translationText = translation }
        guard lyricsMode else { return }
        if changed && animate && Date() >= suppressPushUntil {
            let push = CATransition()
            push.type = .push
            push.subtype = .fromBottom
            push.duration = 0.28
            push.timingFunction = CAMediaTimingFunction(name: .easeOut)
            lyricNow.layer.add(push, forKey: "line")
            lyricTrans.layer.add(push, forKey: "line")
        }
        let frame = CGRect(x: lyricLeft, y: 0, width: lyricRight - lyricLeft, height: 30)
        // Equaliser layout only when the lyric area changes size, not on every lyric refresh.
        if frame != barsFrame {
        barsFrame = frame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // [bars] ♪ [bars], tapering towards the ends.
        let n = Self.barsPerSide, bw: CGFloat = 3.5, gap: CGFloat = 5, mid: CGFloat = 34
        let side = CGFloat(n) * bw + CGFloat(n - 1) * gap
        let total = side * 2 + mid
        dots.frame = CGRect(x: frame.midX - total / 2, y: 0, width: total, height: 30)
        for (i, b) in dotLayers.enumerated() {
            let left = i < n
            let k = left ? i : i - n                                  // 0 = outermost on the left, innermost on the right
            let fromCentre = left ? CGFloat(n - 1 - k) : CGFloat(k)
            let h = 24 * (0.5 + 0.5 * (1 - fromCentre / CGFloat(n)))
            let x = left ? CGFloat(k) * (bw + gap) : side + mid + CGFloat(k) * (bw + gap)
            b.frame = CGRect(x: x, y: (30 - h) / 2, width: bw, height: h)
        }
        noteLayer.frame = CGRect(x: side + (mid - 18) / 2, y: 6, width: 18, height: 18)
        noLyricsBadge.position = CGPoint(x: total + 18 + noLyricsBadge.bounds.width / 2, y: 15)
        CATransaction.commit()
        }
        // With a translation the lyric moves up and shrinks a touch; the translation sits underneath in the song colour.
        let hasTranslation = !translationText.isEmpty
        lyricNow.font = style.font(hasTranslation ? 14 : 16, hasTranslation ? .bold : .heavy)
        lyricNow.set(a, lit: lit, litColor: style.lit, dimColor: style.dim,
                     frame: hasTranslation ? CGRect(x: frame.minX, y: 12, width: frame.width, height: 18) : frame)
        let tint = (palette.accent.blended(withFraction: 0.45, of: .white) ?? palette.accent).withAlphaComponent(0.85)
        lyricTrans.set(translationText, lit: (translationText as NSString).length, litColor: tint, dimColor: tint,
                       frame: CGRect(x: frame.minX, y: 1, width: frame.width, height: 13))
        pausedLine.set(overlayText, lit: overlayLit, litColor: style.text, dimColor: .clear, frame: frame)
    }

    private var isPlaying = false

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        updateRecordSpin()
        updateControlImages()
    }

    func setProgress(_ t: Double, duration d: Double, smooth: Bool = true) {
        duration = d
        position = t
        guard Date().timeIntervalSince(lastScrub) > 1.2, !scrubber.dragging else { return }
        if d > 0 {
            scrubber.enabled = true
            scrubber.setValue(t / d, smooth: smooth)
            elapsedLabel.stringValue = lyricsMode ? fmt(t) + " / " + fmt(d) : fmt(t)
            remainLabel.stringValue = "-" + fmt(max(0, d - t))
        } else {
            scrubber.enabled = false
            scrubber.setValue(0, smooth: false)
            elapsedLabel.stringValue = fmt(t)
            remainLabel.stringValue = "LIVE"
        }
    }

    private func fmt(_ s: Double) -> String {
        let s = Int(s.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
