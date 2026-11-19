//
//  CCSleepItem.swift
//  Pock
//
//  Created by Pierluigi Galdi on 06/07/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//

import AppKit
import Foundation

class CCSleepItem: ControlCenterItem {
    
    override var enabled: Bool { return Defaults[.shouldShowSleepItem] }
    
    override var title: String { return "sleep" }
    
    override func action() -> Any? {
        SystemHelper.lock()
        SystemHelper.sleep()
        return nil
    }
    
}
