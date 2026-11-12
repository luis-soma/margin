import AppKit
import MarginKit
import SwiftUI

/// Setup for the capture shortcut: permissions, and how Margin gets frames
/// out of Figma.
struct SettingsView: View {
    @EnvironmentObject private var coding: CodingSessions
    @EnvironmentObject private var chats: ChatSessions
    @EnvironmentObject private var intelligence: Intelligence
    @EnvironmentObject private var autoCapture: AutoCapture
    /// Shown as a screen in the repo window (its header says "Settings").
    var embedded = false
    @ObservedObject private var profile = Profile.shared
    @AppStorage(ProcessMemory.enabledKey) private var processMemory = true
    @State private var nudges = UserDefaults.standard.object(forKey: "nudgesEnabled") as? Bool ?? true
    @State private var mcp: MCPStatus = .checking
    @State private var token = ""
    @State private var hasToken = Keychain.figmaToken != nil
    @State private var tokenStatus: String?
    @State private var accessibility = DoubleTapShortcut.isTrusted
    @State private var screenRecording = ScreenCapture.hasPermission
    @State private var pluginRunning = false
    /// The branch Update Margin pulls from, as typed.
    @State private var updateBranch = Updater.branch
    /// Keys as you type them; saved to ~/.margin, never shown again.
    @State private var geminiKey = ""
    @State private var openAIKey = ""
    private let pluginTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum MCPStatus: Equatable {
        case checking
        case connected([String])
        case off(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.x8) {
                Text("Settings")
                    .font(Theme.Typography.ui(Theme.Typography.title, .medium))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.top, embedded ? 0 : 34)

                group("You") {
                    HStack(spacing: Theme.Space.x4) {
                        ProfileAvatar(size: 40)
                        VStack(alignment: .leading, spacing: Theme.Space.x2) {
                            field("Your name", text: $profile.name)
                            HStack(spacing: Theme.Space.x2) {
                                button(profile.image == nil ? "Choose picture…" : "Change picture…") { profile.choosePicture() }
                                if profile.image != nil { button("Remove") { profile.removePicture() } }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Theme.Space.x3)
                }

                group("Capturing") {
                    row("Shortcut", "Double-tap ⌘ anywhere, or press ⌘⇧M. Select a frame or text first, or pick an area after.") {
                        EmptyView()
                    }
                    divider
                    VStack(alignment: .leading, spacing: Theme.Space.x2) {
                        row("Documenting", DocumentingSwitch.line(automatic: autoCapture.isEnabled)) {
                            DocumentingSwitch().frame(width: 240)
                        }
                    }
                    divider
                    row("Recordings", "Up to \(Int(AppModel.recordingLimitSeconds)) seconds. Press the shortcut again to stop.") {
                        EmptyView()
                    }
                    divider
                    permissionRow("Accessibility", detail: "For the shortcut, Figma links and selected text.", granted: accessibility) {
                        DoubleTapShortcut.requestTrust()
                        open("Privacy_Accessibility")
                    }
                    divider
                    permissionRow("Screen Recording", detail: "For screenshots and recordings.", granted: screenRecording) {
                        ScreenCapture.requestPermission()
                    }
                }

                group("Connections") {
                    row("Claude Code", codingStatus) {
                        HStack(spacing: Theme.Space.x2) {
                            dot(coding.isConnected ? .green : Theme.Palette.ink3)
                            button(coding.isConnected ? "Disconnect" : "Connect") {
                                if coding.isConnected { coding.disconnect() } else { coding.connect() }
                            }
                            .disabled(coding.port == nil)
                        }
                    }
                    divider
                    row("Learn from Claude Code sessions", "Keeps the decisions from your sessions for summaries and the hand off. Never shown as captures.") {
                        toggle($processMemory)
                    }
                    divider
                    row("Claude app chats", chats.canReadPrompts ? "Vibe coding in the Claude app becomes iterations." : "Type a message with Claude in front to start.") {
                        toggle($chats.isEnabled)
                    }
                    if chats.isEnabled {
                        ForEach(chats.watched, id: \.path) { folder in
                            HStack(spacing: Theme.Space.x2) {
                                Text(folder.lastPathComponent)
                                    .font(Theme.Typography.ui(Theme.Typography.body))
                                    .foregroundStyle(Theme.Palette.ink)
                                Text(folder.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(Theme.Typography.mono(Theme.Typography.caption))
                                    .foregroundStyle(Theme.Palette.ink3)
                                    .lineLimit(1)
                                Spacer()
                                button("Stop watching") { chats.unwatch(folder) }
                            }
                            .padding(.leading, Theme.Space.x4)
                            .padding(.bottom, Theme.Space.x2)
                        }
                        HStack {
                            button("Add project folder…", action: addProject)
                            Spacer()
                        }
                        .padding(.leading, Theme.Space.x4)
                        .padding(.bottom, Theme.Space.x3)
                    }
                    divider
                    row("Figma plugin", pluginRunning ? "Running in Figma." : "Several frames at once, motion as video. Run it once per file from Plugins → Development.") {
                        HStack(spacing: Theme.Space.x2) {
                            dot(pluginRunning ? .green : Theme.Palette.ink3)
                            button("Install plugin", action: installPlugin)
                        }
                    }
                    divider
                    row("Figma token", tokenStatus ?? (hasToken ? "Saved in your keychain." : "A fallback when the plugin isn't running. File content: read.")) {
                        HStack(spacing: Theme.Space.x2) {
                            field(hasToken ? "Token saved" : "figd_…", text: $token, secure: true)
                                .onSubmit(saveToken)
                            if !token.trimmed.isEmpty {
                                button("Save", action: saveToken)
                            } else if hasToken {
                                button("Remove") {
                                    Keychain.figmaToken = nil
                                    hasToken = false
                                    tokenStatus = "Token removed."
                                }
                            }
                        }
                    }
                }

                group("Intelligence") {
                    row("Notes, tabs and summaries", "Off unless you turn it on. Uses your own keys: pictures go to Gemini, sorting to OpenAI. It never writes your why.") {
                        toggle($intelligence.isEnabled)
                            .disabled(!intelligence.config.hasGemini && !intelligence.isEnabled)
                    }
                    divider
                    row("Gemini key", intelligence.config.hasGemini ? "Saved." : "From Google AI Studio.") {
                        keyField(intelligence.config.hasGemini ? "Saved" : "AIza…", text: $geminiKey) {
                            intelligence.saveKeys(gemini: geminiKey)
                            geminiKey = ""
                        }
                    }
                    divider
                    row("OpenAI key", intelligence.config.hasOpenAI ? "Saved." : "Optional: for sorting into tabs.") {
                        keyField(intelligence.config.hasOpenAI ? "Saved" : "sk-…", text: $openAIKey) {
                            intelligence.saveKeys(openai: openAIKey)
                            openAIKey = ""
                        }
                    }
                    if intelligence.isEnabled {
                        divider
                        row("Status", intelligenceStatus) {
                            button("Note earlier captures") { intelligence.backfill() }
                                .disabled(!intelligence.canRun)
                        }
                    }
                }

                // The team's tools, left out of the published app.
                if !BuildInfo.isRelease {
                    group("Demo") {
                        row("Use demo data", "Example projects with their notes already written. Your captures stay untouched; Margin relaunches to switch.") {
                            HStack(spacing: Theme.Space.x2) {
                                if DemoData.isOn {
                                    button("Reset demo") { AppModel.shared.useDemoData(true, reset: true) }
                                }
                                toggle(Binding(get: { DemoData.isOn }, set: { AppModel.shared.useDemoData($0) }))
                            }
                        }
                    }

                    group("Advanced") {
                        row("Update branch", !updateBranch.trimmed.isEmpty && !Updater.isValid(updateBranch.trimmed)
                            ? "Use letters, numbers, - _ . and / only."
                            : "Update Margin pulls this branch, builds it and restarts.") {
                            HStack(spacing: Theme.Space.x2) {
                                field(Updater.defaultBranch, text: $updateBranch)
                                    .onSubmit { saveUpdateBranch() }
                                if updateBranch.trimmed != Updater.branch {
                                    button("Save") { saveUpdateBranch() }
                                }
                            }
                        }
                        divider
                        row("Figma desktop server", statusText) {
                            button("Check again") { Task { await checkMCP() } }
                        }
                        divider
                        row("Troubleshooting", "The log, or a fresh start.") {
                            HStack(spacing: Theme.Space.x2) {
                                button("Open log") { NSWorkspace.shared.open(MarginLog.url) }
                                button("Relaunch") { AppModel.shared.relaunch() }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, embedded ? Archive.Page.margin : 28)
            .padding(.top, embedded ? Archive.Page.top : 0)
            .padding(.bottom, Theme.Space.x12)
            .frame(maxWidth: 640 + 2 * Archive.Page.margin, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(Brand.background)
        .ignoresSafeArea()
        .task { await checkMCP() }
        .onReceive(pluginTick) { _ in pluginRunning = coding.figmaBridge?.isConnected ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibility = DoubleTapShortcut.isTrusted
            screenRecording = ScreenCapture.hasPermission
            coding.refreshConnection()
            Task { await checkMCP() }
        }
    }

    // MARK: Building blocks

    /// A group: its name, then its rows on one light card.
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.x2) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                .foregroundStyle(Theme.Palette.ink)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, Theme.Space.x4)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Palette.raised))
        }
    }

    /// One setting: what it is and a line on what it does, its control on the right.
    private func row<Control: View>(_ title: String, _ detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.x4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.ui(Theme.Typography.body))
                    .foregroundStyle(Theme.Palette.ink)
                if let detail {
                    Text(detail)
                        .font(Theme.Typography.ui(Theme.Typography.caption))
                        .foregroundStyle(Theme.Palette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.x4)
            control()
        }
        .padding(.vertical, Theme.Space.x3)
    }

    private var divider: some View {
        Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.control))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.horizontal, Theme.Space.x3)
                .frame(height: RepoHeader.toolHeight)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.paper))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.Palette.hairline, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .fixedSize()
    }

    @ViewBuilder
    private func field(_ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        Group {
            if secure {
                SecureField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.Palette.ink3))
            } else {
                TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.Palette.ink3))
            }
        }
        .textFieldStyle(.plain)
        .font(Theme.Typography.ui(Theme.Typography.control))
        .foregroundStyle(Theme.Palette.ink)
        .padding(.horizontal, Theme.Space.x2 + 2)
        .frame(width: 200, height: RepoHeader.toolHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.paper))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.Palette.hairline, lineWidth: 1))
    }

    /// A key: typed hidden, saved with Return or the button.
    private func keyField(_ placeholder: String, text: Binding<String>, save: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.x2) {
            field(placeholder, text: text, secure: true)
                .onSubmit(save)
            if !text.wrappedValue.trimmed.isEmpty { button("Save", action: save) }
        }
    }

    private func toggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    // MARK: Pieces

    private var codingStatus: String {
        guard coding.port != nil else { return "Margin couldn't start listening." }
        guard coding.isConnected else { return "Not connected." }
        if let last = coding.lastEvent {
            return "Connected. Last heard from Claude \(last.formatted(.relative(presentation: .named)))."
        }
        return "Connected. Start a new Claude Code session to begin."
    }

    private var statusColor: Color {
        switch mcp {
        case .checking: return .secondary
        case .connected: return .green
        case .off: return .orange
        }
    }

    private var statusText: String {
        switch mcp {
        case .checking: return "Looking for Figma's desktop MCP server…"
        case .connected(let tools):
            let ok = tools.contains("get_screenshot") || tools.contains("get_image")
            return ok ? "Connected to Figma. Frames export automatically." : "Connected, but Figma offers no screenshot tool."
        case .off: return hasToken ? "Figma's desktop server is off. Using your token." : "Figma's desktop server is off."
        }
    }

    private var intelligenceStatus: String {
        let keys = [intelligence.config.hasGemini ? "Gemini" : nil, intelligence.config.hasOpenAI ? "OpenAI Decisions" : nil].compactMap { $0 }
        switch intelligence.status {
        case .off(let reason): return reason
        case .ready: return "Ready · " + keys.joined(separator: " + ")
        case .working(let n): return "Noting \(n) capture\(n == 1 ? "" : "s")"
        case .failed(let message): return "Last call failed: \(message)"
        }
    }

    private var intelligenceColor: Color {
        switch intelligence.status {
        case .ready, .working: return .green
        case .off: return .secondary
        case .failed: return .orange
        }
    }

    private func saveUpdateBranch() {
        Updater.branch = updateBranch
        updateBranch = Updater.branch
    }

    private func permissionRow(_ name: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        row(name, detail) {
            if granted {
                HStack(spacing: Theme.Space.x2) {
                    dot(.green)
                    Text("Allowed")
                        .font(Theme.Typography.ui(Theme.Typography.control))
                        .foregroundStyle(Theme.Palette.ink2)
                }
            } else {
                button("Allow", action: action)
            }
        }
    }

    // MARK: Actions

    private func checkMCP() async {
        mcp = .checking
        switch await FigmaDesktopExporter().status() {
        case .success(let tools): mcp = .connected(tools)
        case .failure(let error): mcp = .off(error.description)
        }
    }

    private func saveToken() {
        let value = token.trimmed
        guard !value.isEmpty else { return }
        tokenStatus = "Checking…"
        Task {
            do {
                let handle = try await FigmaREST.whoAmI(token: value)
                Keychain.figmaToken = value
                hasToken = true
                token = ""
                tokenStatus = "Saved. Signed in as \(handle)."
            } catch {
                tokenStatus = "Figma didn't accept that token."
            }
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose a project folder (a git repository) Claude builds in."
        if panel.runModal() == .OK, let url = panel.url { chats.watch(url) }
    }

    private func installPlugin() {
        do {
            let manifest = try FigmaPlugin.install(to: FigmaPlugin.defaultDirectory)
            NSWorkspace.shared.activateFileViewerSelecting([manifest])
        } catch {
            tokenStatus = "Couldn't write the plugin: \(error.localizedDescription)"
        }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
