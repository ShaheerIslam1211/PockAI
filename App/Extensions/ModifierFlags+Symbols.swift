import AppKit

extension NSEvent.ModifierFlags {
	/// ⌃ ⌥ ⇧ ⌘ symbols for menu shortcut labels (replaces the Magnet dependency).
	func keyEquivalentStrings() -> [String] {
		var out: [String] = []
		if contains(.control) { out.append("⌃") }
		if contains(.option) { out.append("⌥") }
		if contains(.shift) { out.append("⇧") }
		if contains(.command) { out.append("⌘") }
		return out
	}
}
