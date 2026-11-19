//
//  DockItemView.swift
//  Pock
//
//  Created by Pierluigi Galdi on 06/04/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//

import AppKit
import Foundation
import TinyConstraints

class DockItemView: NSScrubberItemView {
    
    /// Core
    private static let kBounceAnimationKey: String = "kBounceAnimationKey"
    private var isAnimating: Bool = false
	private var isMouseOver: Bool = false
	public  var diffId: Int!
    
    /// UI
    public private(set) var contentView:   NSView!
    public private(set) var frontmostView: NSView!
    public private(set) var iconView:      NSImageView!
    public private(set) var dotView:       NSView!
    public private(set) var badgeView:     NSView!
    
    /// Load frontmost
    private func loadFrontmost() {
        self.frontmostView = NSView(frame: .zero)
        self.frontmostView.wantsLayer = true
        self.frontmostView.layer?.masksToBounds = true
        self.frontmostView.layer?.cornerRadius = Constants.dockItemCornerRadius
        self.contentView.addSubview(self.frontmostView, positioned: .below, relativeTo: self.iconView)
		self.frontmostView.edgesToSuperview()
    }
    
    /// Load icon view
    private func loadIconView() {
        self.iconView = NSImageView(frame: .zero)
        self.iconView.imageScaling = .scaleProportionallyDown
        self.iconView.wantsLayer = true
        self.contentView.addSubview(self.iconView)
		self.iconView.size(Constants.dockItemIconSize)
		self.iconView.topToSuperview(offset: 1)
		self.iconView.centerXToSuperview()
    }
    
    /// Load dot view
    private func loadDotView() {
        self.dotView = NSView(frame: NSRect(origin: .zero, size: Constants.dockItemDotSize))
        self.dotView.wantsLayer = true
        self.dotView.layer?.cornerRadius = Constants.dockItemDotSize.width / 2
        self.dotView.layer?.backgroundColor = NSColor.lightGray.cgColor
        self.contentView.addSubview(self.dotView, positioned: .above, relativeTo: self.iconView)
		self.dotView.size(Constants.dockItemDotSize)
		self.dotView.bottomToSuperview()
		self.dotView.centerXToSuperview()
    }
    
    /// Load badge view
    private func loadBadgeView() {
        self.badgeView = NSView(frame: NSRect(origin: .zero, size: Constants.dockItemBadgeSize))
        self.badgeView.wantsLayer = true
        self.badgeView.layer?.cornerRadius = Constants.dockItemBadgeSize.width / 2
        self.badgeView.layer?.backgroundColor = NSColor.red.cgColor
        self.contentView.addSubview(self.badgeView, positioned: .above, relativeTo: self.iconView)
		self.badgeView.size(Constants.dockItemBadgeSize)
		self.badgeView.top(to: iconView, offset: -1)
		self.badgeView.centerXToSuperview(offset: 10)
    }
    
    /// Init
    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Constants.dockItemSize))
        self.contentView = NSView(frame: .zero)
        self.addSubview(self.contentView)
		self.contentView.edgesToSuperview()
    }
    
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func clear() {
        self.set(icon:        nil)
        self.set(hasBadge:    false)
        self.set(isRunning:   false)
        self.set(isFrontmost: false)
    }
    
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale                = window?.backingScaleFactor ?? 1
        iconView?.layer?.contentsScale      = window?.backingScaleFactor ?? 1
        badgeView?.layer?.contentsScale     = window?.backingScaleFactor ?? 1
        dotView?.layer?.contentsScale       = window?.backingScaleFactor ?? 1
        frontmostView?.layer?.contentsScale = window?.backingScaleFactor ?? 1
    }
    
    public func set(isLaunching: Bool) {
        if isLaunching { startBounceAnimation() } else { stopBounceAnimation() }
    }
    public var isLaunching: Bool { return self.isAnimating }
    
    public func set(icon: NSImage?) {
        if iconView == nil { loadIconView() }
        iconView.image = icon.map(DockItemView.touchBarSized)
    }

    /// App icons come as 1024 px multi-representation images; drawn straight into Touch Bar layers each one
    /// costs megabytes. Render once at the Touch Bar's real size (2x) instead: ~100 MB → a few hundred KB.
    private static let iconCache = NSCache<NSImage, NSImage>()
    static func touchBarSized(_ image: NSImage) -> NSImage {
        if let cached = iconCache.object(forKey: image) { return cached }
        let size = Constants.dockItemIconSize
        let pixels = NSSize(width: size.width * 2, height: size.height * 2)
        guard pixels.width > 0, pixels.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: size)
        small.addRepresentation(rep)
        iconCache.setObject(small, forKey: image)
        return small
    }
    
    public func set(isFrontmost: Bool) {
        if frontmostView == nil { loadFrontmost() }
        frontmostView.layer?.backgroundColor = (isFrontmost ? NSColor.darkGray : NSColor.clear).cgColor
    }
    public var isFrontmost: Bool { return frontmostView.layer?.backgroundColor == NSColor.darkGray.cgColor }
    
    public func set(isRunning: Bool) {
        if dotView == nil { loadDotView() }
		dotView.layer?.opacity = isRunning && !Preferences[.hideRunningIndicator] ? 1 : 0
    }
    public var isRunning: Bool { return dotView.layer?.opacity == 1 }
    
    public func set(hasBadge: Bool) {
        if badgeView == nil { loadBadgeView() }
        badgeView.layer?.opacity = hasBadge ? 1 : 0
    }
    public var hasBadge: Bool { return badgeView.layer?.opacity == 1 }
	
	public func set(isMouseOver: Bool) {
		guard isMouseOver else {
			iconView.shadow = nil
			return
		}
		let shadow = NSShadow()
		shadow.shadowBlurRadius = 5
		shadow.shadowOffset		= NSSize(width: 0, height: -2.35)
		shadow.shadowColor		= NSColor.white
		iconView.shadow = shadow
	}
    
}

extension DockItemView: CAAnimationDelegate {
    func startBounceAnimation() {
        if !isAnimating {
            self.loadBounceAnimation()
        }
    }
    private func loadBounceAnimation() {
        isAnimating           = true
        let bounce            = CABasicAnimation(keyPath: "position.y")
        bounce.byValue        = NSNumber(floatLiteral: 10)
        bounce.duration       = 0.325
        bounce.autoreverses   = true
		bounce.isRemovedOnCompletion = true
		bounce.delegate = self
        bounce.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut)
        let frame = self.iconView.layer?.frame
        self.iconView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        self.iconView.layer?.frame = frame ?? .zero
        self.iconView.layer?.add(bounce, forKey: DockItemView.kBounceAnimationKey)
        self.badgeView?.layer?.add(bounce, forKey: DockItemView.kBounceAnimationKey)
    }
    func stopBounceAnimation() {
        self.isAnimating = false
    }
	func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
		startBounceAnimation()
	}
}
