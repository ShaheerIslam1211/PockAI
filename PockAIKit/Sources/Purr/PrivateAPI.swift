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

// MARK: - Private API shims (resolved at runtime, nothing to link)

enum Private {
    static let mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)
    typealias SendCmd = @convention(c) (Int32, CFDictionary?) -> Bool
    typealias SetElapsed = @convention(c) (Double) -> Void
    typealias SetPresence = @convention(c) (CFString, Bool) -> Void
    typealias CloseBox = @convention(c) (Bool) -> Void

    static func send(_ c: Int32) {
        guard let p = dlsym(mr, "MRMediaRemoteSendCommand") else { return }
        _ = unsafeBitCast(p, to: SendCmd.self)(c, nil)
    }
    static func seek(_ t: Double) {
        guard let p = dlsym(mr, "MRMediaRemoteSetElapsedTime") else { return }
        unsafeBitCast(p, to: SetElapsed.self)(t)
    }
    static func stripPresence(_ id: String, _ on: Bool) {
        guard let p = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        unsafeBitCast(p, to: SetPresence.self)(id as CFString, on)
    }
    static func closeBox(_ on: Bool) {
        guard let p = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        unsafeBitCast(p, to: CloseBox.self)(on)
    }
}

enum Cmd: Int32 { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

// MARK: - System-modal Touch Bar (private NSTouchBar class methods), callable from a framework without a bridging header

public enum SystemModalTouchBar {
    private typealias Present = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString?) -> Void
    private typealias Single = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void

    private static func imp(_ name: String) -> IMP? {
        let sel = NSSelectorFromString(name)
        guard let method = class_getClassMethod(NSTouchBar.self, sel) else { return nil }
        return method_getImplementation(method)
    }

    /// placement 1 = whole bar (over the app region), 0 = next to the Control Strip.
    public static func present(_ bar: NSTouchBar, placement: Int64 = 1, trayIdentifier: String? = nil) {
        let name = "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"
        guard let imp = imp(name) else { return }
        unsafeBitCast(imp, to: Present.self)(NSTouchBar.self, NSSelectorFromString(name), bar, placement, trayIdentifier as NSString?)
    }

    public static func dismiss(_ bar: NSTouchBar) {
        let name = "dismissSystemModalTouchBar:"
        guard let imp = imp(name) else { return }
        unsafeBitCast(imp, to: Single.self)(NSTouchBar.self, NSSelectorFromString(name), bar)
    }

    public static func minimize(_ bar: NSTouchBar) {
        let name = "minimizeSystemModalTouchBar:"
        guard let imp = imp(name) else { return }
        unsafeBitCast(imp, to: Single.self)(NSTouchBar.self, NSSelectorFromString(name), bar)
    }
}
