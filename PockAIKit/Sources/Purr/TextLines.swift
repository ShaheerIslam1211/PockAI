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

// MARK: - Scrolling text

final class Marquee {
    let layer = CALayer()
    private let text = CALayer()
    private var current = ""
    private var currentColor: NSColor?
    var font: NSFont { didSet { if font != oldValue { current = ""; currentColor = nil } } }
    var textLayer: CALayer { text }

    init(font: NSFont) {
        self.font = font
        layer.masksToBounds = true
        text.contentsGravity = .left
        layer.addSublayer(text)
    }

    // Drawn with CoreText on the primary font's baseline: fallback fonts (Urdu, Arabic) would otherwise push the line down.
    private func render(_ s: String, color: NSColor, height h: CGFloat) -> (CGImage?, CGFloat) {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attr)
        let w = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 2
        let scale: CGFloat = 2
        guard w > 2, let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, 0) }
        ctx.scaleBy(x: scale, y: scale)
        let base = (h - (font.ascender - font.descender)) / 2 - font.descender
        ctx.textPosition = CGPoint(x: 0, y: base)
        CTLineDraw(line, ctx)
        return (ctx.makeImage(), w)
    }

    func reset() { current = ""; currentColor = nil }

    func set(_ s: String, color: NSColor, frame: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = frame
        let changed = s != current || color != currentColor
        if changed {
            let textChanged = s != current
            current = s; currentColor = color
            let (img, w) = render(s, color: color, height: frame.height)
            text.contents = img
            text.contentsScale = 2
            if textChanged {
                text.removeAllAnimations()
                text.frame = CGRect(x: 0, y: 0, width: max(w, 1), height: frame.height)
                let dist = w - frame.width
                if dist > 1 {
                    let x0 = text.position.x
                    let travel = Double(dist) / 28
                    let hold = 1.8
                    let total = hold + travel + hold + travel
                    let anim = CAKeyframeAnimation(keyPath: "position.x")
                    anim.values = [x0, x0, x0 - dist, x0 - dist, x0]
                    anim.keyTimes = [0, hold / total, (hold + travel) / total, (hold + travel + hold) / total, 1].map { NSNumber(value: $0) }
                    anim.duration = total
                    anim.repeatCount = .infinity
                    text.add(anim, forKey: "marquee")
                }
            }
        }
        CATransaction.commit()
    }
}

// MARK: - Karaoke line: sung part bright, rest dim; long lines slide to keep the current word in view

final class KaraokeLine {
    let layer = CALayer()
    private let text = CALayer()
    var font: NSFont { didSet { if font != oldValue { key = "" } } }
    private var key = ""
    private var currentText = ""
    var centered = false

    init(font: NSFont) {
        self.font = font
        layer.masksToBounds = true
        layer.addSublayer(text)
    }

    var textLayer: CALayer { text }

    func reset() { key = ""; currentText = "" }

    func set(_ s: String, lit: Int, litColor: NSColor, dimColor: NSColor, frame: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = frame
        CATransaction.commit()
        let k = "\(s)|\(lit)|\(litColor)|\(frame.width)"
        guard k != key else { return }
        key = k
        let len = (s as NSString).length
        let attr = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: dimColor])
        attr.addAttribute(.foregroundColor, value: litColor, range: NSRange(location: 0, length: min(max(lit, 0), len)))
        let line = CTLineCreateWithAttributedString(attr)
        let w = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 2
        let h = frame.height
        let scale: CGFloat = 2
        guard w > 2, let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            text.contents = nil
            return
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textPosition = CGPoint(x: 0, y: ((h - font.capHeight) / 2).rounded())
        CTLineDraw(line, ctx)
        let litX = CTLineGetOffsetForStringIndex(line, min(lit, len), nil)
        let newText = s != currentText
        currentText = s

        CATransaction.begin()
        CATransaction.setDisableActions(newText)
        CATransaction.setAnimationDuration(0.35)
        text.contents = ctx.makeImage()
        text.contentsScale = scale
        let overflow = w - frame.width
        let x = overflow > 0 ? (newText ? 0 : -min(overflow, max(0, litX - frame.width * 0.6))) : (centered ? (frame.width - w) / 2 : 0)
        text.frame = CGRect(x: x, y: 0, width: w, height: h)
        CATransaction.commit()
    }
}
