import AppKit
import Foundation

/// Minimal stand-in for the `Defaults` package (only the API this widget uses), so no third-party dependency is needed.
enum Defaults {
	class Keys {}
	final class Key<Value>: Keys {
		let name: String
		let defaultValue: Value
		init(_ name: String, default defaultValue: Value) {
			self.name = name
			self.defaultValue = defaultValue
		}
	}
	static subscript<Value>(key: Key<Value>) -> Value {
		get { UserDefaults.standard.object(forKey: key.name) as? Value ?? key.defaultValue }
		set { UserDefaults.standard.set(newValue, forKey: key.name) }
	}
}
