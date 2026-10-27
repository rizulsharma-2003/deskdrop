import SwiftUI

/// Recent Activity: what was sent and received, with whom, and how it ended.
/// Stored only on this Mac, and only as metadata.
struct TransferHistoryView: View {
    @Environment(DeskDropViewModel.self) private var model
    @State private var selection: HistoryEntry.ID?
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if model.history.entries.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Activity", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Files you send and receive appear here. DeskDrop keeps names and sizes only — never file contents.")
                }
                .accessibilityIdentifier("historyEmpty")
            } else {
                table
            }
        }
        .frame(minWidth: 680, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History", role: .destructive) { confirmingClear = true }
                    .disabled(model.history.entries.isEmpty)
                    .accessibilityIdentifier("clearHistoryButton")
            }
        }
        .confirmationDialog("Clear all recent activity?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { model.history.clear() }
        } message: {
            Text("Files you received stay where they were saved.")
        }
    }

    private var table: some View {
        Table(model.history.entries, selection: $selection) {
            TableColumn("File") { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.direction == .outgoing ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill")
                        .foregroundStyle(entry.direction == .outgoing ? Theme.accent : Theme.violet)
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(entry.detail ?? entry.title)
            }
            .width(min: 180, ideal: 240)

            TableColumn("Person") { entry in
                Text(entry.direction == .outgoing ? "To \(entry.peerName)" : "From \(entry.peerName)")
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Outcome") { entry in
                OutcomeBadge(outcome: entry.outcome)
            }
            .width(min: 90, ideal: 100)

            TableColumn("Size") { entry in
                Text(FileSizeFormatter.string(fromBytes: entry.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Date") { entry in
                Text(entry.date.historyDisplayString())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: HistoryEntry.ID.self) { ids in
            if let entry = entry(for: ids), entry.savedPath != nil {
                Button("Show in Finder") { model.revealHistoryItem(entry) }
            }
        } primaryAction: { ids in
            if let entry = entry(for: ids), entry.savedPath != nil { model.revealHistoryItem(entry) }
        }
        .accessibilityIdentifier("historyTable")
    }

    private func entry(for ids: Set<HistoryEntry.ID>) -> HistoryEntry? {
        guard let id = ids.first else { return nil }
        return model.history.entries.first { $0.id == id }
    }
}

private struct OutcomeBadge: View {
    let outcome: HistoryEntry.Outcome

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var title: String {
        switch outcome {
        case .completed: String(localized: "Completed")
        case .declined: String(localized: "Declined")
        case .cancelled: String(localized: "Cancelled")
        case .failed: String(localized: "Failed")
        case .expired: String(localized: "Expired")
        }
    }

    private var color: Color {
        switch outcome {
        case .completed: Theme.success
        case .declined, .cancelled: .secondary
        case .failed: Theme.danger
        case .expired: Theme.warning
        }
    }
}
