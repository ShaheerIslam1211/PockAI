//
//  PressableSegmentedControler.swift
//  ControlCenter
//
//  Created by Pierluigi Galdi on 18/01/2020.
//  Copyright © 2020 Pierluigi Galdi. All rights reserved.
//

import AppKit
import Foundation
import PockKit

protocol PressableSegmentedControlDelegate: class {
    func didMove(with event: NSEvent, location: NSPoint)
}

class PressableSegmentedControl: NSSegmentedControl {
    
    /// Public
    weak var delegate: PressableSegmentedControlDelegate?
    var didPressAt: ((NSPoint) -> Void)?
    var minimumPressDuration: TimeInterval = 0.55
    
    /// Core
    private var location: NSPoint = .zero
    private var began_time: Date!
    private var timer: Timer?
    private var canMove: Bool = false
    
    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        began_time = Date()
        location = event.allTouches().first?.location(in: self) ?? .zero
        timer?.invalidate()
        // weak, not unowned: the bar can be torn down within the 0.55 s window.
        timer = Timer.scheduledTimer(withTimeInterval: minimumPressDuration, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            self.canMove = true
            self.didPressAt?(self.location)
        })
    }
    
    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        location = event.allTouches().first?.location(in: self) ?? .zero
        timer?.fire()
        if canMove {
            delegate?.didMove(with: event, location: location)
        }
    }
    
    override func touchesCancelled(with event: NSEvent) {
        timer?.invalidate()
        canMove  = false
        location = .zero
        super.touchesCancelled(with: event)
    }

    deinit {
        timer?.invalidate()
    }

    override func touchesEnded(with event: NSEvent) {
        timer?.invalidate()
        canMove  = false
        location = .zero
        super.touchesEnded(with: event)
    }
}
