import AppKit
import ApplicationServices
import Carbon

/// Reads and replaces the selected text in whatever app is in front.
/// Uses the Accessibility API when the app supports it, otherwise ⌘C / ⌘V with the clipboard restored afterwards.
public enum SelectionBridge {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The focused text element of the frontmost app, if Accessibility exposes one.
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value else { return nil }
        return (element as! AXUIElement)
    }

    public static func readSelection() async -> String? {
        if let element = focusedElement() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty {
                return text
            }
        }
        return await copyWithKeystroke()
    }

    /// Replaces the selection in `app` with `text`.
    public static func replaceSelection(with text: String, in app: NSRunningApplication?) async {
        app?.activate()
        try? await Task.sleep(nanoseconds: 180_000_000)
        if let element = focusedElement(),
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            // Some apps report success without changing anything; check before trusting it.
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let all = value as? String, all.contains(text) {
                return
            }
        }
        await pasteWithKeystroke(text)
    }

    // MARK: Clipboard fallback

    private static func copyWithKeystroke() async -> String? {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        let before = board.changeCount
        post(key: CGKeyCode(kVK_ANSI_C))
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if board.changeCount != before { break }
        }
        let text = board.changeCount != before ? board.string(forType: .string) : nil
        restore(board, saved)
        return text
    }

    private static func pasteWithKeystroke(_ text: String) async {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        post(key: CGKeyCode(kVK_ANSI_V))
        try? await Task.sleep(nanoseconds: 400_000_000)
        restore(board, saved)
    }

    /// ⌘Z in the front app (used for "Undo" after a replace).
    public static func undo(in app: NSRunningApplication?) async {
        app?.activate()
        try? await Task.sleep(nanoseconds: 150_000_000)
        post(key: CGKeyCode(kVK_ANSI_Z))
    }

    private static func post(key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        }
    }

    private static func restore(_ board: NSPasteboard, _ items: [[NSPasteboard.PasteboardType: Data]]) {
        board.clearContents()
        let restored = items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}
