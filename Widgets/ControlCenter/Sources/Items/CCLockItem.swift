//
//  CCLockItem.swift
//  Pock
//
//  Created by Pierluigi Galdi on 06/07/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//

import AppKit
import Foundation

class CCLockItem: ControlCenterItem {
    
    override var enabled: Bool { return Defaults[.shouldShowLockItem] }
    
    override var title: String { return "lock" }
    
    override func action() -> Any? {
        SystemHelper.lock()
        return nil
    }
    
}
