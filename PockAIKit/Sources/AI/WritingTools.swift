import AppKit
import SwiftUI

/// Apple-style Writing Tools in a floating panel, for the text selected in any app.
@MainActor
public final class WritingToolsController: ObservableObject {
    public static let shared = WritingToolsController()

    enum Stage { case tools, working, result }

    @Published var stage: Stage = .tools
    @Published var source = ""
    @Published var result = ""
    @Published var title = "Writing Tools"
    @Published var prompt = ""
    @Published var error: String?
    @Published var cameFromSelection = false

    private var panel: NSPanel?
    private var targetApp: NSRunningApplication?
    private var lastRun: (() async throws -> String)?

    /// Grabs the selection from the front app and shows the panel next to the mouse.
    public func show(text: String? = nil) async {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { targetApp = front }
        error = nil
        stage = .tools
        result = ""
        prompt = ""
        if let text {
            source = text
            cameFromSelection = false
        } else if SelectionBridge.isTrusted {
            let selected = await SelectionBridge.readSelection() ?? ""
            source = selected
            cameFromSelection = !selected.isEmpty
            if selected.isEmpty { error = "No text selected — type or paste text below, then pick a tool." }
        } else {
            source = ""
            cameFromSelection = false
            error = "Allow TouchPlay in System Settings → Privacy & Security → Accessibility so it can read and replace selected text."
            SelectionBridge.requestTrust()
        }
        present()
    }

    /// Opens the panel already showing a result made on the Touch Bar (to read it in full or edit further).
    public func show(source: String, result: String, title: String, target: NSRunningApplication?) {
        targetApp = target
        self.source = source
        self.result = result
        self.title = title
        cameFromSelection = target != nil
        error = nil
        stage = .result
        present()
    }

    private func present() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .resizable],
                                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: WritingToolsPanelView(controller: self))
            self.panel = panel
        }
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - panel.frame.height - 12)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }

    public func close() { panel?.orderOut(nil) }

    // MARK: Actions

    func run(_ mode: WritingMode) {
        let text = source
        title = mode.title
        start { try await GeminiClient.shared.run(mode, text: text) }
    }

    func run(template: SharedSettings.Template) {
        let text = source
        title = template.title
        start { try await GeminiClient.shared.custom(template.instruction, text: text) }
    }

    func runPrompt() {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        let text = source
        title = instruction
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start { try await GeminiClient.shared.compose(instruction, context: "") }
        } else {
            start { try await GeminiClient.shared.custom(instruction, text: text) }
        }
    }

    func retry() {
        guard let lastRun else { return }
        start(lastRun)
    }

    private func start(_ work: @escaping () async throws -> String) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !prompt.isEmpty else {
            error = "Select some text first (or type it in the box)."
            return
        }
        lastRun = work
        error = nil
        stage = .working
        Task {
            do {
                result = try await work()
                stage = .result
            } catch {
                self.error = error.localizedDescription
                stage = .tools
            }
        }
    }

    func replace() {
        let text = result
        let app = targetApp
        close()
        Task { await SelectionBridge.replaceSelection(with: text, in: app) }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        title = "Copied ✓"
    }
}

private let intelligence = LinearGradient(colors: [Color(red: 1, green: 0.55, blue: 0.25), .pink, .purple, Color(red: 0.25, green: 0.5, blue: 1)],
                                          startPoint: .leading, endPoint: .trailing)

struct WritingToolsPanelView: View {
    @ObservedObject var controller: WritingToolsController
    @State private var templates = SharedSettings.templates

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(intelligence)
                Text(controller.stage == .tools ? "Writing Tools" : controller.title).font(.title3.bold()).lineLimit(1)
                Spacer()
                Button { controller.close() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }

            switch controller.stage {
            case .tools: tools
            case .working: working
            case .result: resultView
            }
        }
        .padding(18)
        .frame(minWidth: 400, minHeight: 500)
        .background(.ultraThinMaterial)
        .onAppear { templates = SharedSettings.templates }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $controller.source)
                .font(.body)
                .frame(height: 90)
                .hideScrollBackground()
                .padding(6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            if let error = controller.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                TextField("Describe your change", text: $controller.prompt)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .onSubmit { controller.runPrompt() }
                Button { controller.runPrompt() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(intelligence).disabled(controller.prompt.isEmpty)
            }
            HStack(spacing: 8) { big(.fix); big(.rewrite) }
            HStack(spacing: 8) { chip(.friendly); chip(.formal); chip(.shorter) }
            HStack(spacing: 8) { chip(.summarize); chip(.keyPoints); chip(.list); chip(.table) }
            HStack(spacing: 8) { chip(.reply); chip(.english); chip(.emoji); chip(.longer) }
            if !templates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(templates) { template in
                            Button { controller.run(template: template) } label: {
                                Label(template.title, systemImage: "wand.and.stars").padding(.horizontal, 10).frame(height: 30)
                                    .background(Color.purple.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func big(_ mode: WritingMode) -> some View {
        Button { controller.run(mode) } label: {
            Label(mode.title, systemImage: mode.symbol).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ mode: WritingMode) -> some View {
        Button { controller.run(mode) } label: {
            Label(mode.title, systemImage: mode.symbol).font(.caption.weight(.medium)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @State private var angle = 0.0
    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Working…", systemImage: "sparkles").foregroundStyle(intelligence).font(.headline)
            Text(controller.source).foregroundStyle(.secondary).lineLimit(12)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(AngularGradient(colors: [.orange, .pink, .purple, .blue, .cyan, .orange], center: .center, angle: .degrees(angle)), lineWidth: 3)
        )
        .onAppear { withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { angle = 360 } }
    }

    private var resultView: some View {
        VStack(spacing: 10) {
            ScrollView {
                Text(controller.result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                if controller.cameFromSelection {
                    Button("Replace") { controller.replace() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
                Button("Copy") { controller.copy() }
                Button("Retry") { controller.retry() }
                Spacer()
                Button("Back") { controller.stage = .tools }
            }
        }
    }
}


extension View {
    /// `.scrollContentBackground(.hidden)` where available (macOS 13+).
    @ViewBuilder func hideScrollBackground() -> some View {
        if #available(macOS 13.0, *) { self.scrollContentBackground(.hidden) } else { self }
    }
}
