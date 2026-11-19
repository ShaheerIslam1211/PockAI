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

// MARK: - Themes (picked in the menu-bar menu; Default is the original look)

struct ThemeStyle {
    enum Background { case art, artBright, solid(NSColor), gradient([NSColor]), wood, cream }
    enum ArtShape { case rounded, circle, record }
    enum PlayStyle { case accent, white, outline }
    enum Progress { case line, waveform, ascii }
    enum Family { case system, serif, mono, rounded }

    var background: Background = .art
    var accent: NSColor? = nil              // nil: colours come from the cover
    var text: NSColor = .white
    var sub: NSColor? = nil                 // nil: soft version of the accent
    var family: Family = .system
    var uppercase = false
    var artShape: ArtShape = .rounded
    var glow = false
    var play: PlayStyle = .accent
    var progress: Progress = .line
    var lit: NSColor = .white
    var dim: NSColor = NSColor.white.withAlphaComponent(0.38)
    var stripes = false
    var scanlines = false
    var corner: CGFloat = 8

    func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        switch family {
        case .system: return .systemFont(ofSize: size, weight: weight)
        case .serif: return NSFont(name: weight.rawValue >= NSFont.Weight.semibold.rawValue ? "Georgia-Bold" : "Georgia", size: size)
            ?? .systemFont(ofSize: size, weight: weight)
        case .mono: return .monospacedSystemFont(ofSize: size - 0.5, weight: weight)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
        }
    }
}

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}

enum Theme: String, CaseIterable {
    case standard, aurora, vinyl, neon, cassette, pill, waveform, karaoke, island, terminal

    var title: String {
        switch self {
        case .standard: return "Default"
        case .aurora: return "Aurora Glass"
        case .vinyl: return "Vinyl Deck"
        case .neon: return "Neon"
        case .cassette: return "Cassette '79"
        case .pill: return "Quiet Pill"
        case .waveform: return "Waveform"
        case .karaoke: return "Karaoke"
        case .island: return "Island"
        case .terminal: return "Terminal"
        }
    }

    static var current: Theme {
        get { Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme") }
    }

    var style: ThemeStyle {
        var s = ThemeStyle()
        switch self {
        case .standard:
            break
        case .aurora:
            s.background = .artBright
            s.play = .white
            s.sub = NSColor.white.withAlphaComponent(0.8)
            s.family = .rounded
        case .vinyl:
            s.background = .wood
            s.accent = hex(0xe8c27a)
            s.text = hex(0xfff4e0)
            s.sub = hex(0xe8c27a)
            s.family = .serif
            s.artShape = .record
            s.lit = hex(0xfff4e0)
            s.dim = hex(0xfff4e0, 0.4)
        case .neon:
            s.background = .solid(hex(0x05010a))
            s.accent = hex(0xff2bd6)
            s.sub = hex(0x22e4ff)
            s.uppercase = true
            s.glow = true
            s.play = .outline
            s.dim = NSColor.white.withAlphaComponent(0.32)
        case .cassette:
            s.background = .cream
            s.stripes = true
            s.accent = hex(0xe8742a)
            s.text = hex(0x3b2a20)
            s.sub = hex(0xc4441c)
            s.family = .mono
            s.lit = hex(0x3b2a20)
            s.dim = hex(0x3b2a20, 0.35)
        case .pill:
            s.background = .solid(.black)
            s.artShape = .circle
            s.play = .outline
            s.sub = NSColor.white.withAlphaComponent(0.55)
        case .waveform:
            s.progress = .waveform
        case .karaoke:
            s.background = .gradient([hex(0x1b0f2e), hex(0x0d0718), hex(0x1b0f2e)])
            s.accent = hex(0xffd166)
            s.sub = hex(0xffd166)
            s.lit = hex(0xffd166)
            s.dim = NSColor.white.withAlphaComponent(0.45)
            s.family = .rounded
        case .island:
            s.background = .solid(.black)
            s.corner = 15
            s.artShape = .circle
            s.play = .white
        case .terminal:
            s.background = .solid(hex(0x031a0c))
            s.scanlines = true
            s.accent = hex(0x39ff88)
            s.text = hex(0x39ff88)
            s.sub = hex(0x1f8a4c)
            s.family = .mono
            s.progress = .ascii
            s.play = .outline
            s.glow = true
            s.lit = hex(0x39ff88)
            s.dim = hex(0x1f8a4c)
        }
        return s
    }
}

enum ThemeArt {
    // Walnut-ish vertical grain for Vinyl Deck.
    static let wood: CGImage? = {
        let w = 600, h = 30
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var x = 0
        var i = 0
        while x < w {
            let width = 5 + (i * 7) % 11
            let shades: [UInt32] = [0x4a2c1a, 0x5a3620, 0x4f301c, 0x61391f, 0x55331e]
            ctx.setFillColor(hex(shades[i % shades.count]).cgColor)
            ctx.fill(CGRect(x: x, y: 0, width: width, height: h))
            x += width
            i += 1
        }
        return ctx.makeImage()
    }()

    // Thin dark lines every other pixel row, for the Terminal theme.
    static let scanlines: CGImage? = {
        let w = 4, h = 60
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        for y in stride(from: 0, to: h, by: 3) { ctx.fill(CGRect(x: 0, y: y, width: w, height: 1)) }
        return ctx.makeImage()
    }()
}
