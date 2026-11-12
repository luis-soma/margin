import AppKit
import MarginKit
import SwiftUI

/// The live capture panel that opens from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var store: EntryStore
    @EnvironmentObject private var context: AppContextTracker
    @EnvironmentObject private var autoCapture: AutoCapture
    @EnvironmentObject private var coding: CodingSessions
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var chats: ChatSessions

    @State private var isAddingProject = false
    @State private var newProjectName = ""
    /// The mark's dot regrows after each capture.
    @State private var markDot: CGFloat = 1
    @State private var breathe = false
    @State private var shortcutReady = DoubleTapShortcut.isTrusted

    private var app: AppModel { AppModel.shared }

    var body: some View {
        // System tools for the team: one big update button and everything
        // else behind the settings icon.
        HStack(spacing: 8) {
            if BuildInfo.isRelease { Spacer(minLength: 0) } else { updateButton }
            toolsMenu
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            autoCapture.refreshPermission()
            shortcutReady = DoubleTapShortcut.isTrusted
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
        }
        .onChange(of: autoCapture.lastCaptureDate) { _ in
            markDot = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(Brand.motion) { markDot = 1 }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Mark(size: 22, dot: markDot)
            VStack(alignment: .leading, spacing: 2) {
                if isAddingProject {
                    TextField("Project name", text: $newProjectName)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.ui(13, .semibold))
                        .onSubmit(commitProject)
                } else {
                    Menu {
                        ForEach(store.projects, id: \.self) { project in
                            Button(project) { store.currentProject = project }
                        }
                        Divider()
                        Button("New project…") { isAddingProject = true }
                    } label: {
                        Text(store.currentProject)
                            .font(Theme.Typography.ui(13, .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 5, height: 5)
                        .opacity(isLive ? (breathe ? 0.9 : 0.3) : 0.2)
                    Text(statusText)
                        .font(Theme.Typography.ui(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if autoCapture.needsPermission {
                Menu {
                    Button("Open Screen Recording settings") { ScreenCapture.requestPermission() }
                    Button("I allowed it: relaunch Margin") { app.relaunch() }
                } label: {
                    Text("Allow")
                        .font(Theme.Typography.ui(11, .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.fill))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var today: some View {
        let items = store.todaysEntries(in: store.currentProject)
        let shots = Array(items.filter { $0.imageFile != nil }.prefix(6))
        let written = items.filter(\.hasWords).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Today")
                Spacer()
                Text("\(items.count) moments · \(written) with words")
                    .font(Theme.Typography.ui(11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if shots.isEmpty {
                Text("Nothing yet. Margin starts when you work in a design or code app.")
                    .font(Theme.Typography.ui(12))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(shots) { entry in
                        HoverThumbnail(entry: entry) { app.open(entry) }
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            PanelButton(title: "Capture", shortcut: "⌘ ×2") { app.captureMoment() }
            PanelButton(title: "Open repo", shortcut: "⌘O") { app.showRepo() }
                .keyboardShortcut("o", modifiers: .command)
        }
    }

    /// Claude is working on something right now.
    private func codingRow(agent: String, prompt: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.primary)
                .frame(width: 5, height: 5)
                .opacity(breathe ? 0.9 : 0.3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agent) is working")
                    .font(Theme.Typography.ui(11, .medium))
                Text("“\(prompt)”")
                    .font(Theme.Typography.ui(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous).fill(Brand.fill))
    }

    private var updateButton: some View {
        Button {
            if case .failed = updater.state { updater.showLog() } else { app.updateMargin() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: updateIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)
                Text(updateTitle)
                    .font(Theme.Typography.ui(13.5, .semibold))
                    .lineLimit(1)
                    .shimmer(updater.state.isBusy)
                Spacer(minLength: 0)
                if updater.state == .building {
                    Text("about a minute")
                        .font(Theme.Typography.ui(11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background {
                // Fills with a straight edge while the build runs.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: geo.size.width * CGFloat(updater.state.isBusy ? (updater.fraction(at: context.date) ?? 0) : 0))
                            .animation(Brand.motion, value: updater.fraction(at: context.date))
                    }
                }
            }
            .background(Brand.fill)
            .clipShape(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Brand.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(updater.state.isBusy)
        .help(updater.state == .idle ? "Pull the newest version, build it and restart" : updateText)
    }

    private var updateIcon: String {
        switch updater.state {
        case .upToDate: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .checking, .building, .installing: return "arrow.triangle.2.circlepath"
        default: return "arrow.down"
        }
    }

    private var updateTitle: String {
        switch updater.state {
        case .idle: return "Update Margin"
        case .checking: return "Checking for updates"
        case .building: return "Building"
        case .installing: return "Restarting"
        case .upToDate: return "Up to date"
        case .failed: return "Update failed · Show log"
        }
    }

    /// Everything else, for the team: capture tools, nudges, settings.
    private var toolsMenu: some View {
        Menu {
            Toggle("Capture automatically", isOn: $autoCapture.isEnabled)
            Toggle("Nudge me to capture", isOn: Binding(
                get: { app.nudge?.isEnabled ?? false },
                set: { app.nudge?.isEnabled = $0 }
            ))
            Button("Show nudge now") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showNudge() }
            }
            Divider()
            Button("Open repo") { app.showRepo() }
            Button("Capture area…") { app.captureArea(mode: .image) }
            Button("Record area…") { app.captureArea(mode: .recording) }
            Button("Snapshot now") { autoCapture.captureNow() }
            Button("Export Markdown") { app.exportCurrentProject() }
            Divider()
            Button("Show onboarding") { app.showOnboarding() }
            Button("Settings…") { app.showSettings() }
            Button("Quit Margin") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background(Brand.fill, in: RoundedRectangle(cornerRadius: Brand.radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings and tools")
    }

    private var updateRow: some View {
        HStack(alignment: .top, spacing: 8) {
            switch updater.state {
            case .checking, .building, .installing:
                EmptyView()
            case .upToDate:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 14)
            default:
                Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).frame(width: 14, height: 14)
            }
            VStack(alignment: .leading, spacing: 4) {
                if updater.state.isBusy {
                    // The build has a known length on this Mac, so the pill fills.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        ThinkingPill(text: updateStage, fraction: updater.fraction(at: context.date))
                    }
                }
                if !updateText.isEmpty {
                    Text(updateText)
                        .font(Theme.Typography.ui(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed = updater.state {
                    Button("Show update log") { updater.showLog() }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.ui(11, .medium))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var updateStage: String {
        switch updater.state {
        case .checking: return "Checking for updates"
        case .building: return "Building the new version"
        default: return "Restarting Margin"
        }
    }

    private var updateText: String {
        switch updater.state {
        case .idle: return ""
        case .checking: return ""
        case .building: return "About a minute. Keep working."
        case .installing: return ""
        case .upToDate: return "Margin is up to date."
        case .failed(let message): return message
        }
    }

    private var connectHint: some View {
        HStack(spacing: 8) {
            Text("Capture every Claude Code iteration.")
                .font(Theme.Typography.ui(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { coding.connect() } label: {
                Text("Connect")
                    .font(Theme.Typography.ui(11, .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    private var shortcutHint: some View {
        HStack(spacing: 8) {
            Text("Allow Accessibility for the double-tap of ⌘ and to capture Figma frames and selected text.")
                .font(Theme.Typography.ui(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { app.requestShortcutAccess() } label: {
                Text("Allow")
                    .font(Theme.Typography.ui(11, .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("Capture", isOn: $autoCapture.isEnabled)
            Spacer()
            Menu {
                Button("Capture area…") { app.captureArea(mode: .image) }
                Button("Record area…") { app.captureArea(mode: .recording) }
                Button("Log decision…") { app.compose(.decision) }
                Button("Save inspiration…") { app.compose(.inspiration) }
                Divider()
                Button("Snapshot now") { autoCapture.captureNow() }
                Button("Export Markdown") { app.exportCurrentProject() }
                Divider()
                Toggle("Nudge me to capture", isOn: Binding(
                    get: { app.nudge?.isEnabled ?? false },
                    set: { app.nudge?.isEnabled = $0 }
                ))
                Button("Show nudge now") {
                    // After the menu closes, so the pill isn't hidden behind it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { app.showNudge() }
                }
                Divider()
                Button("Show onboarding") { app.showOnboarding() }
                Button("Settings…") { app.showSettings() }
                Button(updater.state.isBusy ? "Updating…" : "Update Margin") { app.updateMargin() }
                    .disabled(updater.state.isBusy)
                Button("Quit Margin") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11))
    }

    // MARK: Helpers

    private var isLive: Bool {
        autoCapture.isEnabled && !autoCapture.needsPermission && context.isInWorkApp
    }

    private var statusText: String {
        if !autoCapture.isEnabled { return "Paused" }
        if autoCapture.needsPermission { return "Needs screen recording access" }
        if context.isInWorkApp, let name = context.appName { return "Capturing \(name)" }
        return "Waiting for a design or code app"
    }

    private func commitProject() {
        guard !newProjectName.trimmed.isEmpty else { return }
        store.currentProject = newProjectName.trimmed
        newProjectName = ""
        isAddingProject = false
    }
}

private struct PanelButton: View {
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Theme.Typography.ui(12, .medium))
                Spacer(minLength: 4)
                Text(shortcut)
                    .font(Theme.Typography.ui(11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftButtonStyle())
    }
}

/// A thumbnail that lifts slightly on hover.
private struct HoverThumbnail: View {
    let entry: Entry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Thumbnail(entry: entry, height: 56)
            .scaleEffect(isHovering ? 1.03 : 1)
            .shadow(color: .black.opacity(isHovering ? 0.18 : 0), radius: 6, y: 2)
            .animation(Brand.motion, value: isHovering)
            .onHover { isHovering = $0 }
            .onTapGesture(perform: action)
    }
}

/// An entry's image, cropped to fill a fixed height, with soft corners.
struct Thumbnail: View {
    @EnvironmentObject private var store: EntryStore
    let entry: Entry
    var height: CGFloat
    var radius: CGFloat = Brand.mediaRadius

    var body: some View {
        Brand.fill
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image = store.thumbnail(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    BracketMark(dot: 0)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: min(height * 0.45, 36), height: min(height * 0.45, 36))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if height >= 50 { KindBadge(entry: entry).padding(5) }
            }
    }
}

/// An entry's image with the other frames of a multi-frame capture stacked
/// behind it, like a small pile of prints.
struct StackedThumbnail: View {
    @EnvironmentObject private var store: EntryStore
    let entry: Entry
    var height: CGFloat
    var radius: CGFloat = Brand.mediaRadius

    private var behind: [FrameRef] {
        Array((entry.frames ?? []).dropFirst().prefix(2))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(behind.enumerated().reversed()), id: \.offset) { index, frame in
                Brand.fill
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let file = frame.imageFile, let image = store.thumbnail(forFile: file) {
                            Image(nsImage: image).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
                    .opacity(index == 0 ? 0.75 : 0.5)
                    .offset(x: CGFloat(index + 1) * 5, y: CGFloat(index + 1) * 5)
            }
            Thumbnail(entry: entry, height: height, radius: radius)
        }
        .padding(.trailing, behind.isEmpty ? 0 : CGFloat(behind.count) * 5)
        .padding(.bottom, behind.isEmpty ? 0 : CGFloat(behind.count) * 5)
    }
}

/// A small mark for captures that aren't plain images.
struct KindBadge: View {
    let entry: Entry

    var body: some View {
        if let text {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                Text(text)
                    .font(Theme.Typography.ui(9, .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.55)))
        }
    }

    private var text: String? {
        switch entry.kind {
        case .recording: return entry.duration.map(RegionMath.duration) ?? "Video"
        case .figma:
            if entry.frameCount > 1 { return "Figma ×\(entry.frameCount)" }
            return entry.duration.map { "Figma \(RegionMath.duration($0))" } ?? "Figma"
        case .link: return URL(string: entry.link)?.host.map { $0.replacingOccurrences(of: "www.", with: "") } ?? "Link"
        case .iteration: return entry.verdictLabel ?? (entry.agent == "Claude Code" ? "Claude" : entry.agent ?? "Code")
        default: return entry.link.isEmpty ? nil : (entry.link.contains("figma.com") ? "Figma" : nil)
        }
    }

    private var symbol: String {
        if entry.duration != nil { return "play.fill" }
        switch entry.kind {
        case .recording: return "play.fill"
        case .iteration:
            switch entry.verdict {
            case "keep": return "checkmark"
            case "deadEnd": return "xmark"
            case "notQuite": return "minus"
            default: return "chevron.left.forwardslash.chevron.right"
            }
        default: return "link"
        }
    }
}
