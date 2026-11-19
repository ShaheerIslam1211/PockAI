//
//  CCScreensaverItem.swift
//  Pock
//
//  Created by Licardo on 2019/11/5.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//

import AppKit
import Foundation

class CCScreensaverItem: ControlCenterItem {
    
    override var enabled: Bool { return Defaults[.shouldShowScreensaverItem] }
    
    override var title: String { return "screensaver" }
    
    override func action() -> Any? {
        let screensaverScript = #"tell application "ScreenSaverEngine" to run"#
        let script = NSAppleScript(source: screensaverScript)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return nil
    }
    
}
