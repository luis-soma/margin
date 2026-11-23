import AppKit
import MarginKit
import SwiftUI

/// Captures on their way to another project: picked up on the timeline or
/// the map, carried over the sidebar, let go on a project's row. The
/// sidebar says where its rows are; the timeline and the map say what's
/// being carried and where the pointer is, in the window's coordinates.
@MainActor
final class CaptureDrag: ObservableObject {
    static let shared = CaptureDrag()
    /// Sent after a move, with a line to show ("Moved 3 captures to Thesis").
    static let moved = Notification.Name("CaptureDrag.moved")

    @Published private(set) var ids: [UUID] = []
    /// The pointer, in the window.
    @Published private(set) var location: CGPoint = .zero
    /// The project row under the pointer, when it isn't the one they're from.
    @Published private(set) var target: String?
    /// The timeline's captures stay put while you drag, so a small stack of
    /// them follows the pointer; the map's move themselves.
    @Published private(set) var showsStack = false

    /// The sidebar's project rows, in the window.
    var rows: [String: CGRect] = [:]
    private var from = ""

    var isActive: Bool { !ids.isEmpty }

    func drag(_ ids: [UUID], from project: String, at point: CGPoint, stack: Bool) {
        if self.ids != ids { self.ids = ids }
        from = project
        showsStack = stack
        location = point
        let over = rows.first { $0.key != project && $0.value.contains(point) }?.key
        if over != target {
            if over != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            withAnimation(Theme.Motion.snappy) { target = over }
        }
    }

    /// Let go: over a project, the captures move there. Returns the project
    /// and how many moved; nil if they weren't over one.
    @discardableResult
    func end(store: EntryStore) -> (project: String, count: Int)? {
        defer { cancel() }
        guard let target, !ids.isEmpty else { return nil }
        for id in ids { store.modify(id) { $0.project = target } }
        let count = ids.count
        MarginLog.info("Moved \(count) captures from \(from) to \(target)")
        let line = count == 1 ? "Moved to \(target)" : "Moved \(count) captures to \(target)"
        NotificationCenter.default.post(name: Self.moved, object: line)
        return (target, count)
    }

    func cancel() {
        ids = []
        withAnimation(Theme.Motion.snappy) { target = nil }
        showsStack = false
    }
}

/// Over the whole window while captures are carried from the timeline: a
/// small stack of them under the pointer and, over a project, where they'll
/// go.
struct CaptureDragLayer: View {
    @ObservedObject private var drag = CaptureDrag.shared
    @EnvironmentObject private var store: EntryStore

    var body: some View {
        GeometryReader { geo in
            if drag.isActive, drag.showsStack {
                let origin = geo.frame(in: .global).origin
                DragStack(entries: drag.ids.prefix(3).compactMap { id in store.entries.first { $0.id == id } },
                          count: drag.ids.count, target: drag.target)
                    .position(x: drag.location.x - origin.x + 46, y: drag.location.y - origin.y + 30)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .allowsHitTesting(false)
        .animation(Theme.Motion.snappy, value: drag.isActive)
    }
}

/// Up to three captures, fanned a little, with how many when it's more than
/// one and, over a project, its name.
private struct DragStack: View {
    let entries: [Entry]
    let count: Int
    let target: String?
    @EnvironmentObject private var store: EntryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    ForEach(Array(entries.enumerated().reversed()), id: \.element.id) { index, entry in
                        card(entry)
                            .rotationEffect(.degrees(Double(index) * 4 - 2))
                            .offset(x: CGFloat(index) * 4, y: CGFloat(index) * 3)
                    }
                }
                if count > 1 {
                    Text("\(count)")
                        .font(Theme.Typography.ui(Theme.Typography.caption, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.paper)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(Theme.Palette.ink))
                        .offset(x: 8, y: -8)
                }
            }
            if let target {
                Text("Move to \(target)")
                    .font(Theme.Typography.ui(Theme.Typography.caption, .medium))
                    .foregroundStyle(Theme.Palette.paper)
                    .padding(.horizontal, Theme.Space.x2)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.Palette.ink))
                    .fixedSize()
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }

    private func card(_ entry: Entry) -> some View {
        ZStack {
            if let file = entry.imageFile {
                AsyncThumbnail(store: store, file: file) { Archive.paper }
            } else {
                WordsThumb(entry: entry, size: CGSize(width: 72, height: 54))
            }
        }
        .frame(width: 72, height: 54)
        .clipped()
        .background(Archive.paper)
        .overlay(Rectangle().stroke(Archive.frame, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
    }
}
