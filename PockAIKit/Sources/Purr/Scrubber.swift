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

// MARK: - Progress bar: slim while idle, grows under the finger

final class Scrubber: NSView {
    var onScrub: ((Double, Bool) -> Void)?
    var onTouch: (() -> Void)?
    var enabled = true { didSet { alphaValue = enabled ? 1 : 0.4 } }
    var accent: NSColor = .systemPink {
        didSet {
            fill.colors = [accent.withAlphaComponent(0.65).cgColor, accent.cgColor]
            knob.shadowColor = accent.cgColor
            if style != .line { relayout(animated: false) }
        }
    }
    var idleSize: (track: CGFloat, knob: CGFloat) = (3, 8) { didSet { relayout(animated: false) } }
    var style: ThemeStyle.Progress = .line { didSet { relayout(animated: false) } }
    var dimColor: NSColor = NSColor.white.withAlphaComponent(0.25) { didSet { if style != .line { relayout(animated: false) } } }
    private var waveBars: [CALayer] = []
    private let ascii = CATextLayer()
    var activeSize: (track: CGFloat, knob: CGFloat) = (7, 20) { didSet { relayout(animated: false) } }
    private(set) var value = 0.0
    private(set) var dragging = false
    private var expanded = false
    private let track = CALayer(), fill = CAGradientLayer(), knob = CALayer()
    private let inset: CGFloat = 11

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        allowedTouchTypes = .direct
        track.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowOpacity = 1
        knob.shadowOffset = .zero
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        for l in [track, fill, knob] { layer?.addSublayer(l) }
        relayout(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout(animated: false)
    }

    func setValue(_ v: Double, smooth: Bool) {
        guard !dragging else { return }
        value = max(0, min(1, v))
        relayout(animated: smooth, duration: 0.5, linear: true)
    }

    func expand() {
        expanded = true
        relayout(animated: true)
        scheduleCollapse()
    }

    private func scheduleCollapse() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(collapse), object: nil)
        perform(#selector(collapse), with: nil, afterDelay: 2.0)
    }

    @objc private func collapse() {
        guard !dragging else { return }
        expanded = false
        relayout(animated: true)
    }

    private func relayout(animated: Bool, duration: Double = 0.3, linear: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: linear ? .linear : .easeOut))
        let w = bounds.width - inset * 2
        let th = expanded ? activeSize.track : idleSize.track
        let kd = expanded ? activeSize.knob : idleSize.knob
        let x = w * CGFloat(value)
        for l in [track, fill, knob] { l.isHidden = style != .line }
        layoutAlternate(width: w)
        track.frame = CGRect(x: inset, y: (bounds.height - th) / 2, width: w, height: th)
        track.cornerRadius = th / 2
        fill.frame = CGRect(x: inset, y: track.frame.minY, width: max(th, x), height: th)
        fill.cornerRadius = th / 2
        knob.bounds = CGRect(x: 0, y: 0, width: kd, height: kd)
        knob.cornerRadius = kd / 2
        knob.position = CGPoint(x: inset + x, y: bounds.height / 2)
        knob.shadowRadius = expanded ? 7 : 3
        CATransaction.commit()
    }

    // Waveform: pseudo-random bars, played part in the accent. ASCII: [████░░░░] in a mono font.
    private func layoutAlternate(width w: CGFloat) {
        let count = max(8, Int(w / 6))
        if style == .waveform {
            while waveBars.count < count {
                let b = CALayer()
                b.cornerRadius = 1
                layer?.addSublayer(b)
                waveBars.append(b)
            }
        }
        for (i, b) in waveBars.enumerated() {
            b.isHidden = style != .waveform || i >= count
            guard !b.isHidden else { continue }
            let v = abs(sin(Double(i) * 0.37) * 0.6 + sin(Double(i) * 0.11) * 0.3 + sin(Double(i) * 1.7) * 0.15)
            let h = CGFloat(4 + v * 16) * (expanded ? 1.25 : 1)
            let step = w / CGFloat(count)
            b.frame = CGRect(x: inset + CGFloat(i) * step, y: (bounds.height - h) / 2, width: max(1.5, step * 0.55), height: h)
            b.backgroundColor = (Double(i) / Double(count) < value ? accent : dimColor).cgColor
        }
        if ascii.superlayer == nil { layer?.addSublayer(ascii) }
        ascii.isHidden = style != .ascii
        if style == .ascii {
            let cells = max(6, Int(w / 7.2) - 2)
            let filled = Int((Double(cells) * value).rounded())
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let str = NSMutableAttributedString(string: "[", attributes: [.font: font, .foregroundColor: dimColor])
            str.append(NSAttributedString(string: String(repeating: "█", count: filled), attributes: [.font: font, .foregroundColor: accent]))
            str.append(NSAttributedString(string: String(repeating: "░", count: cells - filled), attributes: [.font: font, .foregroundColor: dimColor]))
            str.append(NSAttributedString(string: "]", attributes: [.font: font, .foregroundColor: dimColor]))
            ascii.contentsScale = 2
            ascii.string = str
            ascii.frame = CGRect(x: inset, y: (bounds.height - 15) / 2, width: w, height: 15)
        }
    }

    private func follow(_ event: NSEvent, phase: NSTouch.Phase, final: Bool) {
        guard enabled, let t = event.touches(matching: phase, in: self).first else { return }
        let w = bounds.width - inset * 2
        value = max(0, min(1, Double((t.location(in: self).x - inset) / w)))
        relayout(animated: false)
        onScrub?(value, final)
    }

    override func touchesBegan(with event: NSEvent) {
        guard enabled else { return }
        dragging = true
        expanded = true
        onTouch?()
        follow(event, phase: .began, final: false)
        relayout(animated: true)
    }
    override func touchesMoved(with event: NSEvent) { follow(event, phase: .moved, final: false) }
    override func touchesEnded(with event: NSEvent) {
        follow(event, phase: .ended, final: true)
        dragging = false
        scheduleCollapse()
    }
    override func touchesCancelled(with event: NSEvent) {
        dragging = false
        scheduleCollapse()
    }
}
