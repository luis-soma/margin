import AppKit
import SwiftUI

/// The small window for describing a capture, decision, inspiration or note.
struct ComposerView: View {
    @EnvironmentObject private var store: EntryStore
    @State private var draft: Entry
    @State private var tagsText: String

    let onSave: (Entry) -> Void
    let onCancel: (Entry) -> Void

    init(entry: Entry, onSave: @escaping (Entry) -> Void, onCancel: @escaping (Entry) -> Void) {
        _draft = State(initialValue: entry)
        _tagsText = State(initialValue: entry.tags.joined(separator: ", "))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.kind.label)
                    .font(Theme.Typography.ui(13, .semibold))
                Spacer()
                Text(draft.project)
                    .font(Theme.Typography.ui(12))
                    .foregroundStyle(.secondary)
            }

            if let url = store.imageURL(for: draft), let image = ImageTools.picture(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .background(Brand.fill)
            }

            fields

            field("Tags", text: $tagsText, prompt: "comma, separated")

            HStack {
                if draft.kind != .capture {
                    Button(action: pasteImage) {
                        Label("Paste image", systemImage: "doc.on.clipboard")
                    }
                }
                Spacer()
                Button("Cancel") { onCancel(draft) }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            Text("⌘↩ to save · Esc to cancel")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)

    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .capture, .snapshot, .figma, .text, .recording, .iteration, .link:
            field("What is this?", text: $draft.title, prompt: "e.g. Checkout v3, compact card layout")
            area("What's worth remembering about it?", text: $draft.body)
        case .decision:
            field("What did you decide?", text: $draft.title, prompt: "e.g. Bottom sheet instead of a modal")
            area("Why?", text: $draft.rationale)
            area("What else did you consider?", text: $draft.alternatives)
        case .inspiration:
            field("What is it?", text: $draft.title, prompt: "e.g. Linear's empty states")
            field("Link", text: $draft.link, prompt: "https://")
            area("What do you like about it?", text: $draft.body)
        case .note:
            area("Note", text: $draft.body)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Typography.ui(12, .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func area(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.Typography.ui(12, .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: 56)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private func pasteImage() {
        guard let image = NSImage(pasteboard: .general), let file = store.saveImage(image) else {
            NSSound.beep()
            return
        }
        store.discardImage(of: draft)
        draft.imageFile = file
    }

    private func save() {
        var entry = draft
        entry.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(entry)
    }
}
