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

// MARK: - Colours

struct Palette {
    var accent: NSColor
    var second: NSColor
    var deep: NSColor
    var onAccent: NSColor

    static func make(_ base: NSColor) -> Palette {
        let c = base.usingColorSpace(.sRGB) ?? base
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let accent = NSColor(hue: h, saturation: max(s, 0.62), brightness: max(b, 0.92), alpha: 1)
        let second = NSColor(hue: (h + 0.09).truncatingRemainder(dividingBy: 1), saturation: max(s, 0.7), brightness: 0.55, alpha: 1)
        let deep = NSColor(hue: h, saturation: max(s, 0.7), brightness: 0.38, alpha: 1)
        let lum = accent.redComponent * 0.299 + accent.greenComponent * 0.587 + accent.blueComponent * 0.114
        return Palette(accent: accent, second: second, deep: deep, onAccent: lum > 0.68 ? .black : .white)
    }

    static func forApp(_ id: String?) -> Palette {
        switch id ?? "" {
        case "com.spotify.client": return make(NSColor(srgbRed: 0.12, green: 0.84, blue: 0.38, alpha: 1))
        case "com.apple.Music", "com.apple.iTunes": return make(NSColor(srgbRed: 0.98, green: 0.24, blue: 0.36, alpha: 1))
        case "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox":
            return make(NSColor(srgbRed: 1.0, green: 0.2, blue: 0.2, alpha: 1))
        case "com.apple.podcasts": return make(NSColor(srgbRed: 0.6, green: 0.3, blue: 0.95, alpha: 1))
        default: return make(NSColor(srgbRed: 0.55, green: 0.35, blue: 1.0, alpha: 1))
        }
    }

    // Most vivid colour in a downscaled copy of the artwork; nil for greyscale art.
    static func fromArt(_ img: NSImage) -> Palette? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = 12
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var best: NSColor?
        var bestScore: CGFloat = -1
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = NSColor(srgbRed: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255, blue: CGFloat(px[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let score = s * (b > 0.2 ? b : b * 0.2)
            if score > bestScore { bestScore = score; best = c }
        }
        guard let best, bestScore > 0.18 else { return nil }
        return make(best)
    }
}
