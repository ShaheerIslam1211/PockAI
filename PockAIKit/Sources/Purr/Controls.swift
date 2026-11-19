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

// MARK: - Lyrics sync nudge (menu, lyrics view): moves this song's lyrics earlier/later in 0.5 s steps

final class SyncView: NSView {
    static let width: CGFloat = 118
    var onNudge: ((Double) -> Void)?
    private let minus = NSButton()
    private let plus = NSButton()
    private let label = NSTextField(labelWithString: "0.0s")

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: 30) }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 30))
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        for (b, sym, x, desc) in [(minus, "minus", CGFloat(0), "Lyrics later"), (plus, "plus", Self.width - 36, "Lyrics earlier")] {
            b.bezelStyle = .rounded
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: desc)?.withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            b.imagePosition = .imageOnly
            b.bezelColor = NSColor(white: 0.22, alpha: 1)
            b.contentTintColor = .white
            b.frame = NSRect(x: x, y: 0, width: 36, height: 30)
            b.target = self
            b.action = #selector(tap(_:))
            addSubview(b)
        }
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 36, y: 8, width: Self.width - 72, height: 14)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap(_ b: NSButton) { onNudge?(b === plus ? 0.5 : -0.5) }

    func show(_ offset: Double) {
        label.stringValue = offset == 0 ? "0.0s" : String(format: "%+.1fs", offset)
    }
}

// MARK: - Inline volume for the normal view: [quiet speaker] ——●—— [loud speaker]; tap the quiet one to mute

final class VolumeView: NSView {
    static let width: CGFloat = 190
    var onChange: ((Int) -> Void)?
    var onMute: (() -> Void)?
    var accent: NSColor = .white { didSet { slider.accent = accent } }
    var sliderStyle: ThemeStyle.Progress = .line { didSet { slider.style = sliderStyle == .waveform ? .line : sliderStyle } }
    private let low = NSButton()
    private let high = NSImageView()
    private let slider = Scrubber(frame: .zero)
    private var muted = false

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: 30) }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 30))
        low.isBordered = false
        low.imagePosition = .imageOnly
        low.contentTintColor = .white
        low.frame = NSRect(x: 0, y: 0, width: 26, height: 30)
        low.target = self
        low.action = #selector(tapLow)
        addSubview(low)
        high.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Full volume")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        high.contentTintColor = .white
        high.imageAlignment = .alignRight
        high.frame = NSRect(x: Self.width - 24, y: 0, width: 24, height: 30)
        addSubview(high)
        slider.idleSize = (5, 14)
        slider.activeSize = (8, 22)
        slider.frame = NSRect(x: 22, y: 0, width: Self.width - 22 - 26, height: 30)
        slider.onScrub = { [weak self] v, _ in self?.onChange?(Int((v * 100).rounded())) }
        addSubview(slider)
        set(level: 50, muted: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapLow() { slider.expand(); onMute?() }

    var tint: NSColor = .white {
        didSet {
            slider.dimColor = tint.withAlphaComponent(0.25)
            high.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Full volume")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [tint])))
            high.contentTintColor = nil
            low.contentTintColor = nil
            set(level: lastLevel, muted: muted)
        }
    }
    private var lastLevel = 50

    func set(level: Int, muted: Bool) {
        self.muted = muted
        if !slider.dragging { slider.setValue(muted ? 0 : Double(level) / 100, smooth: true) }
        lastLevel = level
        low.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.fill", accessibilityDescription: "Mute")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [tint])))
    }
}

// MARK: - Volume: takes over the whole bar when opened from the menu

final class VolumeFullView: NSView {
    var onChange: ((Int) -> Void)?
    var onMute: (() -> Void)?
    var onTouch: (() -> Void)?
    var palette = Palette.forApp(nil) { didSet { applyPalette() } }
    let slider = Scrubber(frame: .zero)
    private let bg = CAGradientLayer()
    private let muteButton = NSButton()
    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint?
    private var currentWidth: CGFloat = 930
    private var level = 50
    private var muted = false

    override var intrinsicContentSize: NSSize { NSSize(width: currentWidth, height: 30) }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 930, height: 30))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        widthConstraint = widthAnchor.constraint(equalToConstant: currentWidth)
        widthConstraint?.isActive = true
        bg.startPoint = CGPoint(x: 0, y: 0.5)
        bg.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(bg)

        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.contentTintColor = .white
        muteButton.target = self
        muteButton.action = #selector(tapMute)
        addSubview(muteButton)

        slider.idleSize = (10, 22)
        slider.activeSize = (14, 28)
        slider.onScrub = { [weak self] v, _ in
            guard let self else { return }
            self.level = Int((v * 100).rounded())
            self.muted = self.level == 0
            self.updateLabels()
            self.onChange?(self.level)
        }
        slider.onTouch = { [weak self] in self?.onTouch?() }
        addSubview(slider)

        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        label.textColor = .white
        label.alignment = .right
        addSubview(label)
        relayout()
        applyPalette()
        updateLabels()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setWidth(_ w: CGFloat) {
        guard w != currentWidth else { return }
        currentWidth = w
        widthConstraint?.constant = w
        invalidateIntrinsicContentSize()
        relayout()
    }

    private func relayout() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.frame = CGRect(x: 0, y: 0, width: currentWidth, height: 30)
        CATransaction.commit()
        muteButton.frame = NSRect(x: 4, y: 0, width: 40, height: 30)
        slider.frame = NSRect(x: 46, y: 0, width: currentWidth - 46 - 74, height: 30)
        label.frame = NSRect(x: currentWidth - 70, y: 5, width: 60, height: 20)
    }

    private func applyPalette() {
        bg.colors = [palette.deep.cgColor, palette.second.withAlphaComponent(0.6).cgColor, NSColor.black.cgColor]
        slider.accent = palette.accent
    }

    @objc private func tapMute() { onTouch?(); onMute?() }

    func set(level: Int, muted: Bool) {
        self.level = level
        self.muted = muted
        if !slider.dragging { slider.setValue(muted ? 0 : Double(level) / 100, smooth: true) }
        updateLabels()
    }

    private func updateLabels() {
        label.stringValue = muted ? "Muted" : "\(level)%"
        let name = muted || level == 0 ? "speaker.slash.fill" : level < 34 ? "speaker.wave.1.fill" : level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        muteButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Mute")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
    }
}
