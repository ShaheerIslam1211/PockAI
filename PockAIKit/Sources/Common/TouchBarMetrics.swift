import AppKit

/// How wide the Touch Bar really is on this Mac, so full-bar layouts (player, lyrics, AI options)
/// fill it exactly on 13", 15" and 16" MacBook Pros instead of using one hard-coded width.
///
/// - 13" / 15" (2016–2020, incl. M1/M2 13"): 2170 px panel = 1085 pt, of which ~76 pt is the Esc area.
/// - 16" (2019): 2008 px panel = 1004 pt, Esc is a real key so the whole panel is usable.
///
/// The live width of the presented bar is measured when available; the model table is the fallback.
public enum TouchBarMetrics {

	public enum Size: String, CaseIterable {
		case auto, standard, sixteenInch
		public var title: String {
			switch self {
			case .auto: return "Automatic"
			case .standard: return "13\" / 15\" MacBook Pro"
			case .sixteenInch: return "16\" MacBook Pro"
			}
		}
	}

	/// User override (Settings → Touch Bar size). `.auto` detects it.
	public static var preferredSize: Size {
		get { Size(rawValue: UserDefaults.standard.string(forKey: "pockai.touchBarSize") ?? "") ?? .auto }
		set { UserDefaults.standard.set(newValue.rawValue, forKey: "pockai.touchBarSize"); cachedLive = nil }
	}

	/// `hw.model`, e.g. "MacBookPro15,1".
	public static let modelIdentifier: String = {
		var size = 0
		sysctlbyname("hw.model", nil, &size, nil, 0)
		guard size > 0 else { return "" }
		var buffer = [CChar](repeating: 0, count: size)
		sysctlbyname("hw.model", &buffer, &size, nil, 0)
		return String(cString: buffer)
	}()

	/// True on the 16" models whose Touch Bar has no Esc area (MacBookPro16,1 and 16,4).
	public static var isSixteenInch: Bool {
		switch preferredSize {
		case .standard: return false
		case .sixteenInch: return true
		case .auto: return ["MacBookPro16,1", "MacBookPro16,4"].contains(modelIdentifier)
		}
	}

	/// Whole panel width in points.
	public static var panelWidth: CGFloat { isSixteenInch ? 1004 : 1085 }

	/// Points taken by the Esc / close-box area on the left of a full-width system-modal bar.
	/// PockAI (like Pock) removes the close box and its padding, so full-bar screens get the whole panel.
	public static var escAreaWidth: CGFloat { 0 }

	private static var cachedLive: CGFloat?

	/// Width of the app region of the live Touch Bar, measured from the system's function-row views.
	public static var liveAppRegionWidth: CGFloat? {
		guard preferredSize == .auto else { return nil }
		if let cachedLive { return cachedLive }
		guard let cls = NSClassFromString("NSFunctionRow") as? NSObject.Type else { return nil }
		let sel = NSSelectorFromString("_topLevelViews")
		guard cls.responds(to: sel), let views = cls.perform(sel)?.takeUnretainedValue() as? [NSView] else { return nil }
		let widest = views.map { $0.window?.frame.width ?? $0.bounds.width }.max() ?? 0
		guard widest > 300, widest <= 1100 else { return nil }
		cachedLive = widest
		return widest
	}

	/// Re-measure on the next request (call after the bar is (re)presented or the layout style changes).
	public static func invalidate() { cachedLive = nil }

	/// Width available to content in a full-width system-modal bar (Esc area removed),
	/// minus `reserved` points for buttons the caller places next to its main view.
	public static func fullBarContentWidth(reserving reserved: CGFloat = 0) -> CGFloat {
		// The live function-row windows reflect the *current* bar (often the narrower Control Strip layout),
		// not a full-width modal bar, so use the panel size for full-bar screens.
		let base = panelWidth - escAreaWidth
		// Item spacing + outer insets.
		return max(300, floor(base - reserved - 20))
	}

	/// Width available when the Control Strip (≈ 4 buttons on the right) stays visible.
	public static func withControlStripContentWidth(reserving reserved: CGFloat = 0) -> CGFloat {
		return max(240, fullBarContentWidth(reserving: reserved) - 180)
	}
}
