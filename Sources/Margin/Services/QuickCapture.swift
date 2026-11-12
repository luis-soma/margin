import AppKit
import AVFoundation
import Combine
import QuartzCore
import SwiftUI

/// A borderless panel that can take keyboard input without pulling the
/// designer out of the app they're working in.
class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Esc anywhere in the panel, even when nothing inside took the keyboard.
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
}

/// What the card panel shows: a loading pill while a capture is in the
/// works, then the card itself. The same panel morphs from one to the other.
@MainActor
final class CardStage: ObservableObject {
    enum Content {
        /// The capture menu's shape, standing in for the menu while the
        /// capture is taken (with a picture of the menu fading off it).
        case menu(NSImage, CGSize)
        case loading(String)
        case card(AnyView)
    }

    @Published var content: Content {
        didSet { step += 1 }
    }
    /// Counts changes of form, so the host knows when to move.
    @Published private(set) var step = 0
    /// Real progress for the loading pill (0...1), nil when it can't be known.
    @Published var fraction: Double?
    /// Changes with every new card, so its state starts fresh.
    @Published var cardID = UUID()
    /// Leaving: the card rises a little and fades, the way it came.
    @Published var closing = false

    /// The capture menu, when the stage started as its stand-in: the host
    /// starts from the menu's shape even if the stage has moved on by the
    /// time it first appears.
    let startedAsMenu: (image: NSImage, size: CGSize)?

    init(_ content: Content) {
        self.content = content
        if case .menu(let image, let size) = content { startedAsMenu = (image, size) } else { startedAsMenu = nil }
    }

    var isMenu: Bool {
        if case .menu = content { return true }
        return false
    }

    /// Waiting for the card: the menu's stand-in or the loading pill.
    var isLoading: Bool {
        switch content {
        case .menu, .loading: return true
        case .card: return false
        }
    }
}

/// The capture card that drops in under the menu bar, top center:
/// project, the capture, "Saved", and an optional annotation.
@MainActor
final class QuickCaptureController {
    private var panel: KeyablePanel?
    /// Esc dismisses the card wherever the keyboard is: in the card, or
    /// still in the app you captured from.
    private var escMonitors: [Any] = []
    private var stage: CardStage?
    private var loadingTimeout: DispatchWorkItem?
    /// Who opened the current card, so they can close only their own.
    private(set) var tag: String?
    /// The card's width. Narrow enough to sit under the notch like an island.
    static let cardWidth: CGFloat = 380
    /// Room around the card for its shadow.
    private static let margin: CGFloat = 30

    /// Takes over from the capture menu: its shape stays where it was while
    /// the capture is taken, then becomes the card (or, if saving takes a
    /// moment, the loading pill with its drop).
    func handOff(menu image: NSImage, size: CGSize) {
        loadingTimeout?.cancel()
        dismissImmediately()
        let stage = CardStage(.menu(image, size))
        self.stage = stage
        panel = makePanel(stage: stage, takeFocus: false)
        // A quick capture goes from the menu straight into the card; only
        // a save that takes a while passes through the loading pill.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak stage] in
            guard let stage, case .menu = stage.content else { return }
            stage.content = .loading("Saving")
        }
        let timeout = DispatchWorkItem { [weak self] in
            if self?.stage?.isLoading == true { self?.close() }
        }
        loadingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    /// A small "working on it" pill where the card will appear. The next
    /// `show` turns it into the card.
    /// - Parameter fraction: how far along, when Margin can actually tell
    ///   (frames exported so far). nil keeps the pill a plain shimmer.
    func showProgress(_ text: String, fraction: Double? = nil) {
        loadingTimeout?.cancel()
        if let stage, stage.isLoading, panel != nil {
            stage.content = .loading(text)
            withAnimation(Brand.motion) { stage.fraction = fraction }
        } else {
            dismissImmediately()
            let stage = CardStage(.loading(text))
            stage.fraction = fraction
            self.stage = stage
            panel = makePanel(stage: stage, takeFocus: false)
        }
        // Don't leave a pill up if nothing follows.
        let timeout = DispatchWorkItem { [weak self] in
            if self?.stage?.isLoading == true { self?.close() }
        }
        loadingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timeout)
    }

    /// - Parameters:
    ///   - entryID: the moment the annotation belongs to, if it already exists.
    ///   - status: small label, e.g. "Saved".
    ///   - prompt: a question shown above the field.
    func show(
        store: EntryStore,
        entryID: UUID?,
        image: NSImage?,
        status: String?,
        prompt: String?,
        detail: String? = nil,
        quote: String? = nil,
        beforeImage: NSImage? = nil,
        choices: [(id: String, label: String)] = [],
        placeholder: String? = nil,
        takeFocus: Bool = true,
        idleTimeout: TimeInterval = 5,
        tag: String? = nil,
        onChoice: ((String?, String) -> Void)? = nil,
        onSave: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        loadingTimeout?.cancel()
        let view = CaptureCardView(
            store: store,
            entryID: entryID,
            image: image,
            status: status,
            prompt: prompt,
            detail: detail,
            quote: quote,
            beforeImage: beforeImage,
            choices: choices,
            placeholder: placeholder,
            idleTimeout: idleTimeout,
            onChoice: onChoice.map { handler in
                { [weak self] choice, text in
                    handler(choice, text)
                    self?.close()
                }
            },
            onSave: { [weak self] text in
                onSave(text)
                self?.close()
            },
            onDismiss: { [weak self] in
                onDismiss()
                self?.close()
            }
        )
        self.tag = tag
        let escape = { [weak self] in
            onDismiss()
            self?.close()
        }
        // A loading pill is up: let it become the card, and give it the
        // keyboard the same way a fresh card gets it, so Esc and typing work.
        if let stage, stage.isLoading, let panel {
            stage.cardID = UUID()
            stage.content = .card(AnyView(view))
            panel.onEscape = escape
            watchEscape(escape)
            if takeFocus { focus(panel) }
            return
        }
        dismissImmediately()
        self.tag = tag
        let stage = CardStage(.card(AnyView(view)))
        self.stage = stage
        let panel = makePanel(stage: stage, takeFocus: takeFocus)
        panel.onEscape = escape
        self.panel = panel
        watchEscape(escape)
        if takeFocus { focus(panel) }
    }

    /// Makes the card the key window, and checks again a moment later in
    /// case the app being captured (Figma, a browser) took it back.
    private func focus(_ panel: KeyablePanel) {
        panel.makeKeyAndOrderFront(nil)
        for delay in [0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak panel] in
                guard let panel, self?.panel === panel, !panel.isKeyWindow else { return }
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func makePanel(stage: CardStage, takeFocus: Bool) -> KeyablePanel {
        // Wide enough for the capture menu's shape, which the card can grow out of.
        let frame = NSRect(x: 0, y: 0, width: 640, height: 520)
        let panel = KeyablePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstClickHostingView(rootView: CardHost(stage: stage))
        host.frame = frame
        panel.contentView = host
        // Top center of the screen you're looking at, under the menu bar and
        // notch. The panel is transparent; the card hangs from its top edge.
        if let screen = TopCenter.screen {
            panel.setFrameOrigin(TopCenter.origin(for: frame.size, on: screen))
        }
        if takeFocus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Don't take the keyboard from the app you're typing in.
            panel.orderFrontRegardless()
        }
        // Out of the notch: it swells after the card. Not when the card takes
        // over from the capture bar in place; the bar already came out.
        if case .menu = stage.content {} else { NotchPulse.shared.release() }
        return panel
    }

    var isOpen: Bool { panel != nil }

    /// The card has the keyboard: someone is typing in it.
    var isBeingUsed: Bool { panel?.isKeyWindow ?? false }

    /// Closes the card only if `tag` opened it.
    func close(tag: String) {
        if self.tag == tag { close() }
    }

    /// Closes a loading pill (when the capture didn't produce a card).
    func closeProgress() {
        if stage?.isLoading == true { close() }
    }

    /// The card rises a little and fades out (the way it came), then goes.
    func close() {
        guard let panel else { return }
        let leaving = stage
        self.panel = nil
        stage = nil
        tag = nil
        loadingTimeout?.cancel()
        removeEscape()
        withAnimation(.timingCurve(0.4, 0, 0.7, 0.2, duration: 0.22)) { leaving?.closing = true }
        // Back into the notch: it takes the card in as it reaches it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NotchPulse.shared.take() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { panel.orderOut(nil) }
    }

    private func watchEscape(_ escape: @escaping () -> Void) {
        removeEscape()
        let isEsc: (NSEvent) -> Bool = { $0.keyCode == 53 }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard isEsc(event) else { return event }
            DispatchQueue.main.async { escape() }
            return nil
        }) { escMonitors.append(local) }
        // While the app you captured from still has the keyboard.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            guard isEsc(event) else { return }
            DispatchQueue.main.async { escape() }
        }) { escMonitors.append(global) }
    }

    private func removeEscape() {
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
    }

    func dismissImmediately() {
        removeEscape()
        panel?.orderOut(nil)
        panel = nil
        stage = nil
        tag = nil
        loadingTimeout?.cancel()
    }
}

/// Shape and finish shared by the pill and the card.
enum Island {
    /// The capture menu's corner radius: the card and the loading pill share it.
    static let cardRadius = Theme.Radius.card
    static let pillHeight: CGFloat = 36
    static let innerRadius = Theme.Radius.control
    static let padding = Theme.Space.x4
}

/// The shape under the menu bar, in the capture menu's own style (paper and
/// ink, a hairline, a soft shadow). It hangs from the top edge and changes
/// form like a liquid: the capture menu (or, while saving, a plain pill)
/// swells softly underneath and grows into the card. Once still, the card
/// is a plain crisp shape with its hairline.
struct CardHost: View {
    @ObservedObject var stage: CardStage
    @Environment(\.colorScheme) private var scheme
    @State private var liquid = Liquid()
    @State private var appeared = false
    /// The card has stopped moving: draw it crisp and stop the frame clock.
    @State private var settled = false
    /// What's on top (the card, the pill's word) has faded in.
    @State private var contentShown = false
    /// The card is unfolding from the capture menu: its parts rise in.
    @State private var unfolds = false
    /// The picture of the capture menu, kept on its stand-in until the
    /// shape starts to move, then leaving the way the menu's parts do.
    @State private var menuPicture: (image: NSImage, size: CGSize)?
    @State private var menuLeaving = false
    /// The hairline, drawn once the shape is still.
    @State private var lined = false
    /// When the loading pill started, for its estimated fill.
    @State private var loadingSince = Date()

    private var ink: MenuInk { MenuInk(scheme) }

    private var shadowStrength: (Double, Double) { scheme == .dark ? (0.5, 0.45) : (0.08, 0.16) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if !settled { surface }
            // What's on top is cut to the moving shape: nothing shows where
            // there's no fill behind it.
            foreground
                .padding(.top, Liquid.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask { shapeMask }
            // The loading stroke sits on the pill's edge, half outside it, so
            // it's drawn on its own rather than cut to the shape.
            if case .loading(let text) = stage.content {
                LoadingPill(text: text.hasSuffix("…") ? text : text + "…",
                            fraction: stage.fraction, since: loadingSince, ink: ink, part: .stroke)
                    .opacity(contentShown ? 1 : 0)
                    .padding(.top, Liquid.top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            if let menuPicture {
                MenuLeaving(image: menuPicture.image, size: menuPicture.size, leaving: menuLeaving)
                    .padding(.top, Liquid.menuTop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .mask { shapeMask }
                    .allowsHitTesting(false)
            }
        }
        // Arrives like the capture menu: down from under the menu bar,
        // sharpening as it lands. Leaves the same way, back up. No bounce.
        .scaleEffect(appeared && !stage.closing ? 1 : 0.96, anchor: .top)
        .blur(radius: appeared && !stage.closing ? 0 : 3)
        .offset(y: appeared && !stage.closing ? 0 : -14)
        .opacity(appeared && !stage.closing ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if let menu = stage.startedAsMenu, !stage.isMenu {
                // The stage moved on before the first frame: start from the menu anyway.
                appeared = true
                liquid.showMenu(width: menu.size.width)
                menuPicture = menu
                begin(fresh: false)
                return
            }
            begin(fresh: true)
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.36)) { appeared = true }
        }
        .onChange(of: stage.step) { _ in begin(fresh: false) }
    }

    /// The moving shape as a mask; once the card is still, nothing is cut.
    @ViewBuilder
    private var shapeMask: some View {
        if settled {
            Rectangle()
        } else {
            TimelineView(.animation) { _ in
                Canvas { context, size in liquid.draw(in: context, size: size) }
            }
        }
    }

    /// The moving shape: white paper
    /// cut to the liquid outline.
    private var surface: some View {
        TimelineView(.animation) { timeline in
            let _ = liquid.advance(to: timeline.date)
            Rectangle()
                .fill(ink.surface)
                .mask(Canvas { context, size in liquid.draw(in: context, size: size) })
        }
        .compositingGroup()
        .shadow(color: .black.opacity(shadowStrength.0), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(shadowStrength.1), radius: 18, y: 8)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var foreground: some View {
        Group {
            switch stage.content {
            case .menu:
                // The menu's picture sits in its own layer (see `menuPicture`).
                Color.clear.frame(width: 1, height: 1)
            case .loading(let text):
                // A light grey stroke chases itself round the pill until the
                // card arrives.
                LoadingPill(text: text.hasSuffix("…") ? text : text + "…",
                            fraction: stage.fraction, since: loadingSince, ink: ink)
                .opacity(contentShown ? 1 : 0)
            case .card(let view):
                view
                    .environment(\.cardUnfolds, unfolds)
                    .id(stage.cardID)
                    .opacity(contentShown ? 1 : 0)
                    .foregroundStyle(ink.text)
                    .background {
                        // Still: the card sits on solid white with the card shadow.
                        if settled {
                            FloatingSurface(shape: shape)
                        }
                    }
                    .overlay {
                        shape.strokeBorder(ink.hairline, lineWidth: 1)
                            .opacity(lined ? 1 : 0)
                    }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { liquid.contentSize = $0 }
    }

    /// Moves to whatever the stage shows now.
    private func begin(fresh: Bool) {
        settled = false
        lined = false
        let step = stage.step
        // Leaving the menu's shape: its parts go as the shape starts to move.
        if menuPicture != nil, !stage.isMenu {
            menuLeaving = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { menuPicture = nil }
        }
        switch stage.content {
        case .menu(let image, let size):
            appeared = true
            liquid.showMenu(width: size.width)
            menuPicture = (image, size)
            menuLeaving = false
            contentShown = false
        case .loading:
            if !stage.isLoading || fresh || !(previousWasLoading) { loadingSince = Date() }
            liquid.showWaiting(fresh: fresh)
            contentShown = false
            withAnimation(.easeOut(duration: 0.16).delay(fresh ? 0 : 0.08)) { contentShown = true }
        case .card where fresh:
            // Nothing came before: the card simply arrives.
            contentShown = true
            settled = true
            lined = true
        case .card:
            let fromMenu: Bool
            if case .menu = liquid.mode { fromMenu = true } else { fromMenu = false }
            liquid.showCard(now: Date())
            if fromMenu {
                // A sheet unfolding from the bar: the card's parts rise into
                // place one after another as it opens (see `cardUnfolds`).
                unfolds = true
                contentShown = true
            } else {
                // From the pill: its word leaves, the card's contents fade in
                // as the shape fills out.
                unfolds = false
                contentShown = false
                withAnimation(.easeOut(duration: 0.2).delay(0.12)) { contentShown = true }
            }
            settleWhenCalm(step: step, after: 0.18)
        }
    }

    /// The step before was the loading pill too (only its words changed).
    private var previousWasLoading: Bool {
        if case .waiting = liquid.mode { return true }
        return false
    }

    /// Swaps in the crisp card once the liquid has come to rest.
    private func settleWhenCalm(step: Int, after delay: TimeInterval, waited: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard stage.step == step else { return }
            if liquid.isCalm || waited > 1 {
                settled = true
                withAnimation(.easeOut(duration: 0.15)) { lined = true }
            } else {
                settleWhenCalm(step: step, after: 0.05, waited: waited + delay)
            }
        }
    }
}

/// The loading pill: its word, and a fill from the left that moves as one
/// smooth motion. It follows the larger of an easing estimate and the real
/// progress (when Margin knows it), only ever forward, and glides toward it
/// a little each frame, so a late real number never makes it jump.
private struct LoadingPill: View {
    let text: String
    let fraction: Double?
    let since: Date
    let ink: MenuInk
    /// The words (cut to the pill's shape) or the stroke round its edge.
    enum Part { case words, stroke }
    var part: Part = .words

    /// One round of the stroke: it draws on, then its tail follows the head
    /// away, so the line keeps travelling round the pill.
    static let cycle: Double = 2.2

    var body: some View {
        Text(text)
            .font(Theme.Typography.ui(12, .medium))
            .foregroundStyle(ink.muted)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 18)
            .frame(height: Island.pillHeight)
            .opacity(part == .words ? 1 : 0)
            .overlay {
                if part == .stroke { stroke }
            }
    }

    private var stroke: some View {
                TimelineView(.animation) { timeline in
                    let u = (timeline.date.timeIntervalSince(since) / Self.cycle).truncatingRemainder(dividingBy: 1)
                    let head = Self.ease(min(u / 0.6, 1))
                    let tail = Self.ease(max(0, (u - 0.4) / 0.6))
                    // A grey line centered on the pill's edge, on its own
                    // corners (the capture menu's).
                    RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous)
                        .trim(from: tail, to: max(tail + 0.0001, head))
                        .stroke(Color.primary.opacity(0.42), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
    }

    /// Slow out, quick through the middle, slow in.
    static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// The capture menu's words and icons, fading out quickly as the shape
/// starts to move, while the card's contents fade in.
private struct MenuLeaving: View {
    let image: NSImage
    let size: CGSize
    let leaving: Bool

    var body: some View {
        Image(nsImage: image)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .opacity(leaving ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: leaving)
    }
}

struct CaptureCardView: View {
    @ObservedObject var store: EntryStore
    let entryID: UUID?
    let image: NSImage?
    let status: String?
    let prompt: String?
    let detail: String?
    var quote: String? = nil
    var beforeImage: NSImage? = nil
    var choices: [(id: String, label: String)] = []
    var placeholder: String? = nil
    var idleTimeout: TimeInterval = 5
    var onChoice: ((String?, String) -> Void)? = nil
    let onSave: (String) -> Void
    let onDismiss: () -> Void
    @State private var choice: String?
    /// Answered or dismissed: ignore further ticks while the card fades out.
    @State private var finished = false

    @State private var text = ""
    @State private var lastActivity = Date()
    @FocusState private var focused: Bool
    /// Speaking the note: what was typed before, so heard words go after it.
    @StateObject private var voice = VoiceInput()
    @State private var typedBeforeVoice = ""

    @Environment(\.colorScheme) private var scheme
    private var ink: MenuInk { MenuInk(scheme) }

    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private let contentWidth = QuickCaptureController.cardWidth - Island.padding * 2

    private var project: String {
        entryID.flatMap { store.entry(id: $0)?.project } ?? store.currentProject
    }

    /// The words of a text capture, shown as text rather than a picture.
    private var capturedText: String? {
        guard let entry = entryID.flatMap({ store.entry(id: $0) }), entry.kind == .text else { return nil }
        let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// Frames in this capture (several Figma frames show as a stack).
    private var frameCount: Int {
        entryID.flatMap { store.entry(id: $0)?.frameCount } ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            header
                .unfoldIn(0)

            if let prompt {
                Text(prompt)
                    .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                    .foregroundStyle(ink.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail)
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(ink.muted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            media
                // A little more room above and below the picture.
                .padding(.vertical, 6)
                .unfoldIn(1)

            if let quote {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.primary.opacity(0.25))
                        .frame(width: 2)
                    Text(quote)
                        .font(Theme.Typography.ui(12.5))
                        .lineSpacing(2)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if !choices.isEmpty {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.id) { option in
                        ChoiceChip(label: option.label, selected: choice == option.id) {
                            withAnimation(Brand.quick) { choice = option.id }
                            lastActivity = Date()
                        }
                    }
                }
            }

            // One optional line: why this, in your words. The microphone comes
            // first, since saying it is faster than typing mid-flow; the
            // capture is already saved, so skipping costs nothing.
            HStack(spacing: Theme.Space.x2) {
                VoiceButton(voice: voice, toggle: toggleVoice)
                TextField("", text: $text, prompt: Text(voice.listening && text.isEmpty ? "Listening…" : placeholder ?? (prompt == nil ? "Why this?" : "One line")).foregroundColor(ink.muted))
                    .textFieldStyle(.plain)
                    .font(Archive.sans(Theme.Typography.body))
                    .foregroundStyle(ink.text)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { voice.cancel(); onDismiss() }
            }
            .unfoldIn(2)
        }
        // Invisible button that carries the Escape shortcut; behind the card
        // so it adds no space under the field.
        .background {
            Button("") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .padding(Island.padding)
        .frame(width: QuickCaptureController.cardWidth, alignment: .leading)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onChange(of: text) { _ in lastActivity = Date() }
        // Heard words appear in the field as you speak, after what you typed.
        .onChange(of: voice.transcript) { heard in
            guard !heard.isEmpty else { return }
            let joiner = typedBeforeVoice.isEmpty || typedBeforeVoice.hasSuffix(" ") ? "" : " "
            text = typedBeforeVoice + joiner + heard
        }
        .onDisappear { voice.cancel() }
        .onReceive(tick) { now in
            if voice.listening { lastActivity = now; return }
            // Looking at the picture, or dragging it somewhere, counts as
            // working on the card.
            if ImagePreview.shared.isOpen || NSEvent.pressedMouseButtons != 0 { lastActivity = now; return }
            let idle = now.timeIntervalSince(lastActivity)
            guard text.isEmpty, !finished else { return }
            if let choice, let onChoice, idle > 3 {
                // Picked an answer and didn't start typing: that's the answer.
                finished = true
                onChoice(choice, "")
            } else if choice == nil, idle > idleTimeout {
                finished = true
                onDismiss()
            }
        }
    }

    /// "Saved to Umbrella" on the left (the project can be changed from
    /// there); on the right the esc key to dismiss, or return to save once
    /// you've typed something.
    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            if status != nil {
                Text("Saved to")
                    .font(Archive.sans(Theme.Typography.caption))
                    .foregroundStyle(ink.muted)
            }
            projectMenu
            Spacer(minLength: 8)
            // The key in its little outline, as before: esc, or return once
            // you've typed something.
            if text.trimmed.isEmpty {
                KeyHint(key: "esc", label: "to dismiss", ink: ink)
            } else {
                KeyHint(key: "return", label: "to save", ink: ink)
            }
        }
        .animation(Brand.quick, value: text.trimmed.isEmpty)
    }

    @ViewBuilder
    private var media: some View {
        if let text = capturedText {
            // Text you captured: the words themselves, no box behind them,
            // black in light mode and white in dark, between a large pair of
            // quotation marks (the closing one level with the last line).
            let ink = scheme == .dark ? Color.white : Color.black
            VStack(alignment: .leading, spacing: 0) {
                quoteMark("\u{201C}", ink: ink)
                Text(text)
                    .font(Archive.sans(Archive.Focus.noteSize))
                    .foregroundStyle(ink)
                    .lineSpacing(3)
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .overlay(alignment: .bottomTrailing) {
                        quoteMark("\u{201D}", ink: ink).offset(y: 4)
                    }
            }
        } else if let beforeImage, let image {
            // Before and after, side by side.
            let w = (contentWidth - 22) / 2
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    cardImage(beforeImage, width: w, height: w * 0.62, open: { openPreview([beforeImage, image], at: 0) }).opacity(0.75)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    cardImage(image, width: w, height: w * 0.62, file: captureFile, open: { openPreview([beforeImage, image], at: 1) })
                }
                HStack {
                    Text("Before").frame(width: w, alignment: .leading)
                    Spacer(minLength: 0)
                    Text("After").frame(width: w, alignment: .leading)
                }
                .font(Theme.Typography.ui(11))
                .foregroundStyle(ink.muted)
            }
        } else if let image {
            if frameCount > 1 {
                stackPreview(image)
            } else {
                cardImage(image, width: contentWidth, height: 150, file: captureFile, video: cardVideo, open: { openPreview(fullImages(fallback: image)) })
                    .overlay(alignment: .bottomLeading) {
                        if isBuild { cornerPill("Build").padding(.leading, pictureInset(image)) }
                    }
                    .frame(width: contentWidth, height: 150)
            }
        }
    }

    /// Several frames at once (a Figma multi-select or a deck): the first
    /// frame in front, the next two behind it, each the picture's own shape,
    /// stepping up and to the right like prints on a desk. The count sits
    /// quietly on the front frame.
    @ViewBuilder
    private func stackPreview(_ image: NSImage) -> some View {
        let step: CGFloat = 7
        let behind = backFrames
        let layers = CGFloat(behind.count)
        let boxW = contentWidth - step * layers, boxH = 150 - step * layers
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.6
        let fw = min(boxW, boxH * aspect), fh = fw / aspect
        // The whole stack centered in the card's picture area.
        let originX = (contentWidth - fw - step * layers) / 2
        let originY = step * layers + (150 - fh - step * layers) / 2
        ZStack(alignment: .topLeading) {
            ForEach(Array(behind.enumerated()).reversed(), id: \.offset) { index, back in
                let depth = CGFloat(index + 1)
                Image(nsImage: back)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(width: fw, height: fh)
                    .clipped()
                    .overlay(Rectangle().fill(Color.black.opacity(0.04 * Double(depth))))
                    .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                    .offset(x: originX + depth * step, y: originY - depth * step)
                    .allowsHitTesting(false)
            }
            cardImage(image, width: fw, height: fh, file: captureFile, video: cardVideo, open: { openPreview(fullImages(fallback: image)) })
                .overlay(alignment: .bottomLeading) { cornerPill("\(frameCount) frames") }
                .offset(x: originX, y: originY)
        }
        .frame(width: contentWidth, height: 150 + step * layers, alignment: .topLeading)
    }

    /// One of the large, soft quotation marks around captured text.
    private func quoteMark(_ mark: String, ink: Color) -> some View {
        Text(mark)
            .font(.custom("Georgia", fixedSize: 44))
            .foregroundStyle(ink.opacity(scheme == .dark ? 0.24 : 0.18))
            .frame(height: 22, alignment: .top)
            .accessibilityHidden(true)
    }

    /// A quiet label on the picture's corner: how many frames, or that it's a build.
    private func cornerPill(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.ui(10.5, .medium))
            .foregroundStyle(ink.text)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(Capsule().fill(ink.surface))
            .overlay(Capsule().strokeBorder(ink.hairline, lineWidth: 1))
            .padding(7)
            .allowsHitTesting(false)
    }

    /// A build from a coding agent.
    private var isBuild: Bool {
        entryID.flatMap { store.entry(id: $0)?.kind } == .iteration
    }

    /// Where a fitted picture starts inside the card's full-width box, so a
    /// pill sits on the picture rather than the empty space beside it.
    private func pictureInset(_ image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return 0 }
        let shown = min(contentWidth, 150 * image.size.width / image.size.height)
        return (contentWidth - shown) / 2
    }

    /// The frames behind the first in a stack (at most two), as thumbnails;
    /// plain paper where a frame has no picture yet.
    private var backFrames: [NSImage] {
        guard let entry = entryID.flatMap({ store.entry(id: $0) }) else { return [] }
        let files = (entry.frames ?? []).dropFirst().prefix(2).compactMap(\.imageFile)
        let pictures = files.compactMap { store.thumbnail(forFile: $0) }
        if pictures.count == min(frameCount - 1, 2) { return pictures }
        // Not exported yet: the front picture stands in, dimmed by depth.
        let front = entry.imageFile.flatMap { store.thumbnail(forFile: $0) }
        return Array(repeating: front, count: min(frameCount - 1, 2)).compactMap { $0 }
    }

    private func cardImage(_ image: NSImage, width: CGFloat, height: CGFloat, file: (() -> URL?)? = nil, video: URL? = nil, open: @escaping () -> Void) -> some View {
        // Linked somewhere (a saved web page, say): the archive's link mark
        // on the picture's own top-right corner.
        let entry = entryID.flatMap { store.entry(id: $0) }
        let mark = entry.flatMap(CornerMark.of) ?? (links ? CornerMark(symbol: "link", help: "Links to its source") : nil)
        return CardImage(image: image, width: width, height: height, file: file, mark: mark, video: video, open: open)
    }

    /// The capture's video (a Figma animation, a recording), once it's saved.
    private var cardVideo: URL? {
        guard let entry = entryID.flatMap({ store.entry(id: $0) }),
              let url = store.mediaURL(for: entry),
              ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// This capture links to its source.
    private var links: Bool {
        guard let entry = entryID.flatMap({ store.entry(id: $0) }) else { return false }
        return !entry.link.isEmpty
    }

    /// The capture as a file to drag out of the card, into a chat or a
    /// folder: the recording itself, else the screenshot. It goes as a copy
    /// with a readable name, so the store's own file stays put.
    private func captureFile() -> URL? {
        lastActivity = Date()
        guard let entry = entryID.flatMap({ store.entry(id: $0) }),
              let source = store.mediaURL(for: entry) ?? store.imageURL(for: entry) else { return nil }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = source.pathExtension.lowercased()
        let kind = ["mp4", "mov", "m4v"].contains(ext) ? "Recording" : ["png", "jpg", "jpeg", "heic"].contains(ext) ? "Screenshot" : "Capture"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Margin drag", isDirectory: true)
            .appendingPathComponent(entry.id.uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent("\(kind) \(stamp.string(from: entry.createdAt)).\(source.pathExtension)")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do { try FileManager.default.copyItem(at: source, to: copy) } catch { return source }
        }
        return copy
    }

    /// The capture at full size: every frame of a stack, else the image file,
    /// else the thumbnail the card already has.
    private func fullImages(fallback: NSImage) -> [NSImage] {
        guard let entry = entryID.flatMap({ store.entry(id: $0) }) else { return [fallback] }
        let files = (entry.frames ?? []).compactMap(\.imageFile)
        let loaded = (files.isEmpty ? [entry.imageFile].compactMap { $0 } : files)
            .compactMap { ImageTools.picture(at: store.imageURL(forFile: $0)) }
        return loaded.isEmpty ? [fallback] : loaded
    }

    /// Opens the picture large, with the annotation field. Leaving the
    /// preview (Return, Esc or a click outside) finishes the card too: what
    /// was typed is saved, and with nothing typed the card just goes away.
    private func openPreview(_ images: [NSImage], at index: Int = 0) {
        lastActivity = Date()
        ImagePreview.shared.show(
            images, at: index, note: text,
            onNote: { note in
                text = note
                finished = true
                submit()
            },
            onSubmit: { note in
                text = note
                finished = true
                submit()
            }
        )
    }

    /// The project, with its caret to the right; pick another to move the capture.
    private var projectMenu: some View {
        Menu {
            ForEach(store.projects, id: \.self) { name in
                Button(name) { move(to: name) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(project)
                    .font(Archive.sans(12))
                    .foregroundStyle(ink.text)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ink.muted)
            }
            .contentShape(Rectangle())
        }
        // A plain label, so it starts on the content's edge with no button inset.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func move(to name: String) {
        lastActivity = Date()
        store.currentProject = name
        if let entryID {
            store.modify(entryID) { $0.project = name }
        }
    }

    /// The microphone: start listening, or stop and keep the words.
    private func toggleVoice() {
        lastActivity = Date()
        if voice.listening {
            voice.stop()
        } else {
            typedBeforeVoice = text
            voice.start()
        }
        focused = true
    }

    private func submit() {
        // Return while listening keeps the words; a second Return saves.
        if voice.listening {
            voice.stop()
            return
        }
        let line = text.trimmed
        if let onChoice, choice != nil || !line.isEmpty {
            onChoice(choice, line)
        } else if line.isEmpty {
            onDismiss()
        } else {
            onSave(line)
        }
    }
}

/// A picture on the card, whole and in its own shape (square edges, a round
/// frame stays round), never cropped or framed. Click it to see it full
/// size; drag it out to hand over the file. It stays still on hover.
private struct CardImage: View {
    let image: NSImage
    let width: CGFloat
    let height: CGFloat
    var file: (() -> URL?)? = nil
    /// Where it lives (Figma, a build, a link), as in the archive.
    var mark: CornerMark? = nil
    /// A video to play over the picture, silent and on a loop (the picture
    /// is its first frame, so it fits the same shape).
    var video: URL? = nil
    let open: () -> Void

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay(
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .overlay {
                        if let video {
                            CardFilm(url: video)
                                .id(video)
                                .allowsHitTesting(false)
                        }
                    }
                    // On the picture itself, as on the archive's thumbnails.
                    .overlay(alignment: .topTrailing) {
                        if let mark {
                            mark.padding(6)
                        }
                    }
                    // The shadow follows the picture's own outline.
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onDrag {
                guard let url = file?() else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            } preview: {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(width, 160), height: min(height, 110))
            }
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(file == nil ? "Click to see it full size" : "Click to see it full size, or drag it into a chat or folder")
    }
}

/// A video on the card: silent, playing on a loop as soon as it's there,
/// letterboxed inside the picture's shape. Clicks and drags pass through to
/// the picture underneath.
private struct CardFilm: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> FilmView { FilmView(url: url) }
    func updateNSView(_ view: FilmView, context: Context) {}
    static func dismantleNSView(_ view: FilmView, coordinator: ()) { view.stop() }

    final class FilmView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let film = AVPlayerLayer()

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            film.player = player
            film.videoGravity = .resizeAspect
            layer?.addSublayer(film)
            player.play()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func stop() {
            player.pause()
            looper?.disableLooping()
            film.player = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            film.frame = bounds
            CATransaction.commit()
        }
    }
}

/// A calm, small choice: outlined until picked.
private struct ChoiceChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.Typography.ui(12, .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .foregroundStyle(selected ? Brand.background : Color.primary.opacity(0.85))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.primary.opacity(0.88) : Color.primary.opacity(hovering ? 0.07 : 0.0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(selected ? 0 : 0.14), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Brand.quick, value: hovering)
    }
}

/// "ESC dismiss": a key cap in the capture menu's style and what it does.
struct KeyHint: View {
    let key: String
    let label: String
    let ink: MenuInk
    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(Theme.Typography.mono(9, .medium))
                .padding(.horizontal, 5)
                .frame(height: 17)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink.hairline, lineWidth: 1))
            Text(label)
                .font(Archive.sans(12))
        }
        .foregroundStyle(ink.muted)
    }
}

private struct CardUnfoldsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The card is unfolding from the capture menu like a sheet.
    var cardUnfolds: Bool {
        get { self[CardUnfoldsKey.self] }
        set { self[CardUnfoldsKey.self] = newValue }
    }
}

/// One part of a card unfolding from the capture menu: it rises a little
/// into place and fades in, a beat after the part above it.
private struct UnfoldIn: ViewModifier {
    let order: Int
    @Environment(\.cardUnfolds) private var unfolds
    @State private var arrived = false

    func body(content: Content) -> some View {
        content
            .opacity(!unfolds || arrived ? 1 : 0)
            .offset(y: !unfolds || arrived ? 0 : 8)
            // The card can be on screen a moment before it's told it's
            // unfolding, so start from either.
            .onAppear { if unfolds { rise() } }
            .onChange(of: unfolds) { if $0 { rise() } }
    }

    /// Quickly, each part a beat after the one above it.
    private func rise() {
        withAnimation(.easeOut(duration: 0.24).delay(0.04 + 0.06 * Double(order))) { arrived = true }
    }
}

extension View {
    fileprivate func unfoldIn(_ order: Int) -> some View { modifier(UnfoldIn(order: order)) }
}
