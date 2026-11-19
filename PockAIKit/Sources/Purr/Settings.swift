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

// MARK: - Settings shown in the menu-bar menu

enum BatterySaver: String, CaseIterable {
    case automatic, always, off
    var title: String {
        switch self {
        case .automatic: return "Automatic (on battery or Low Power Mode)"
        case .always: return "Always"
        case .off: return "Off"
        }
    }
    static var current: BatterySaver {
        get { BatterySaver(rawValue: UserDefaults.standard.string(forKey: "batterySaver") ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "batterySaver") }
    }
}

enum NightMode: String, CaseIterable {
    case automatic, always, off
    var title: String {
        switch self {
        case .automatic: return "Automatic (10 pm – 7 am)"
        case .always: return "Always"
        case .off: return "Off"
        }
    }
    static var current: NightMode {
        get { NightMode(rawValue: UserDefaults.standard.string(forKey: "nightMode") ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "nightMode") }
    }
    var isOn: Bool {
        switch self {
        case .always: return true
        case .off: return false
        case .automatic:
            let h = Calendar.current.component(.hour, from: Date())
            return h >= 22 || h < 7
        }
    }
}

enum KeepAwake: Int, CaseIterable {
    case off = 0, m5 = 300, m15 = 900, m30 = 1800, playing = -1
    var title: String {
        switch self {
        case .off: return "Off (macOS default)"
        case .m5: return "5 minutes"
        case .m15: return "15 minutes"
        case .m30: return "30 minutes"
        case .playing: return "While music plays"
        }
    }
    static var current: KeepAwake {
        get { KeepAwake(rawValue: UserDefaults.standard.object(forKey: "keepAwake") as? Int ?? 0) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "keepAwake") }
    }
}

enum HideWhenPaused: Int, CaseIterable {
    case s30 = 30, m2 = 120, m5 = 300, never = 0
    var title: String {
        switch self {
        case .s30: return "After 30 seconds"
        case .m2: return "After 2 minutes"
        case .m5: return "After 5 minutes"
        case .never: return "Never"
        }
    }
    static var current: HideWhenPaused {
        get { HideWhenPaused(rawValue: UserDefaults.standard.object(forKey: "hideWhenPaused") as? Int ?? 120) ?? .m2 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hideWhenPaused") }
    }
}

enum Power {
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
