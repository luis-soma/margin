import AppKit
import SwiftUI

/// After a drop: the files, each with its name, what it becomes and when it
/// happened, to check before they go in. Everything is already filled in from
/// the files themselves, so Return adds them as they are.
struct ImportReview: View {
    @Binding var items: [FileImport.Item]
    let project: String
    let add: () -> Void
    let cancel: () -> Void
    @State private var adding = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(items.count == 1 ? "Add to \(project)" : "Add \(items.count) files to \(project)")
                    .font(Theme.Typography.ui(Theme.Typography.body, .medium))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Check what each becomes and when it happened.")
                    .font(Theme.Typography.ui(Theme.Typography.caption))
                    .foregroundStyle(Theme.Palette.ink3)
            }
            .padding(.horizontal, Theme.Space.x4)
            .padding(.top, Theme.Space.x4)
            .padding(.bottom, Theme.Space.x3)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach($items) { $item in
                        ImportRow(item: $item)
                        if item.id != items.last?.id {
                            Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.x3)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Palette.raised))
                .padding(.horizontal, Theme.Space.x3)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.x2) {
                Spacer()
                ReviewButton(title: "Cancel", primary: false, action: cancel)
                    .keyboardShortcut(.cancelAction)
                ReviewButton(title: adding ? "Adding…" : "Add", primary: true) {
                    adding = true
                    add()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(adding || items.isEmpty)
            }
            .padding(Theme.Space.x3)
        }
        .frame(width: 440)
        .background(FloatingSurface(shape: shape))
        .clipShape(shape)
    }
}

/// One file: its picture, its name, what it becomes and when.
private struct ImportRow: View {
    @Binding var item: FileImport.Item

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.x3) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $item.name)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.ui(Theme.Typography.body))
                    .foregroundStyle(Theme.Palette.ink)
                HStack(spacing: Theme.Space.x2) {
                    KindMenu(kind: $item.kind, kinds: item.kinds)
                    DateField(date: $item.date)
                }
            }
        }
        .padding(.vertical, Theme.Space.x3)
    }

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return ZStack {
            shape.fill(Theme.Palette.paper)
            if let preview = item.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(item.kind == .file ? 6 : 0)
            }
        }
        .frame(width: 56, height: 42)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1))
    }
}

/// What a file becomes, as a chip that opens a short menu.
private struct KindMenu: View {
    @Binding var kind: FileImport.Kind
    let kinds: [FileImport.Kind]
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(kinds) { option in
                Button {
                    kind = option
                } label: {
                    Label(option.name + "  ·  " + option.detail, systemImage: option.symbol)
                }
            }
        } label: {
            chip
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(kinds.count < 2)
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol)
                .font(.system(size: 10.5, weight: .medium))
            Text(kind.name)
                .font(Theme.Typography.ui(Theme.Typography.control))
            if kinds.count > 1 {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink3)
            }
        }
        .foregroundStyle(Theme.Palette.ink)
        .padding(.horizontal, Theme.Space.x2)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(hovering && kinds.count > 1 ? Theme.Palette.fillHover : Theme.Palette.fill))
    }
}

/// When it happened: the day and time, typed or stepped.
private struct DateField: View {
    @Binding var date: Date

    var body: some View {
        DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .datePickerStyle(.field)
            .font(Theme.Typography.ui(Theme.Typography.control))
            .controlSize(.small)
            .padding(.horizontal, Theme.Space.x2)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.Palette.fill))
            .fixedSize()
    }
}

/// Cancel and Add: 28 tall, Add in ink.
private struct ReviewButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.ui(Theme.Typography.control, primary ? .medium : .regular))
                .foregroundStyle(primary ? Theme.Palette.paper : Theme.Palette.ink)
                .padding(.horizontal, Theme.Space.x4)
                .frame(height: 28)
                .background(shape.fill(primary
                    ? Theme.Palette.ink.opacity(hovering && enabled ? 0.86 : 1)
                    : (hovering ? Theme.Palette.fillHover : Theme.Palette.fill)))
                .opacity(enabled ? 1 : 0.5)
                .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .onHover { inside in withAnimation(Theme.Motion.hover) { hovering = inside } }
    }
}
