import AppKit
import SwiftUI

extension EntryKind {
    var color: Color {
        switch self {
        case .capture: return .blue
        case .decision: return .green
        case .inspiration: return .orange
        case .note: return .gray
        case .snapshot: return .secondary
        case .figma: return .purple
        case .text: return .teal
        case .recording: return .red
        case .iteration: return .indigo
        case .link: return .cyan
        }
    }
}

struct EntryRow: View {
    @EnvironmentObject private var store: EntryStore
    let entry: Entry
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(compact ? .callout : .body.weight(.medium))
                    .lineLimit(compact ? 1 : 2)
                HStack(spacing: 4) {
                    Text(entry.createdAt, style: .time)
                    if let app = entry.sourceApp {
                        Text("· \(app)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !compact {
                    details
                        .font(.callout)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if let url = store.imageURL(for: entry), let image = ImageTools.picture(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: compact ? 36 : 120, height: compact ? 36 : 80)
                    .clipped()
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if !entry.body.isEmpty, entry.body != entry.displayTitle {
            Text(entry.body)
        }
        if !entry.rationale.isEmpty {
            Text("Why: ").bold() + Text(entry.rationale)
        }
        if !entry.alternatives.isEmpty {
            Text("Also considered: ").bold() + Text(entry.alternatives)
        }
        if !entry.link.isEmpty, let url = URL(string: entry.link) {
            Link(entry.link, destination: url)
                .lineLimit(1)
        }
        if !entry.tags.isEmpty {
            Text(entry.tags.map { "#\($0)" }.joined(separator: " "))
                .foregroundStyle(.secondary)
        }
    }
}
