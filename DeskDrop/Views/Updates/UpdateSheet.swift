import SwiftUI

/// "DeskDrop 1.8.0 is available": what's new, who has it, and Update.
struct UpdateSheet: View {
    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var updates: UpdateService { model.updates }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if let notes = updates.available?.manifest.notes, !notes.isEmpty {
                ScrollView {
                    MarkdownTextView(text: notes, outgoing: false)
                        .font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            }

            status

            HStack {
                Text("Only updates signed by DeskDrop’s publisher are installed. Your old copy goes to the Trash.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(updates.phase == .installing)
                Button(updates.available?.isDownloaded == true ? "Install and Relaunch" : "Update and Relaunch") {
                    updates.clearFailure()
                    updates.update()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(updates.available == nil || isBusy)
                .accessibilityIdentifier("installUpdateButton")
            }
        }
        .padding(20)
        .frame(width: 500)
        .accessibilityIdentifier("updateSheet")
    }

    private var isBusy: Bool {
        switch updates.phase {
        case .downloading, .installing: true
        default: false
        }
    }

    private var title: String {
        guard let available = updates.available else { return String(localized: "DeskDrop is up to date") }
        return String(localized: "DeskDrop \(available.manifest.version) is available")
    }

    private var subtitle: String {
        guard let available = updates.available else { return String(localized: "You have version \(updates.currentVersion).") }
        let size = FileSizeFormatter.string(fromBytes: available.manifest.archiveSize)
        if available.isDownloaded {
            return String(localized: "You have \(updates.currentVersion) · \(size), ready to install")
        }
        let names = available.sources.compactMap { model.peer($0)?.displayName }
        let from = names.first.map { String(localized: " · from \($0)") } ?? ""
        return String(localized: "You have \(updates.currentVersion) · \(size)\(from)")
    }

    @ViewBuilder
    private var status: some View {
        switch updates.phase {
        case .idle:
            EmptyView()
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: fraction)
                Text("Downloading from a colleague’s Mac…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing… DeskDrop will reopen in a moment.")
                    .font(.system(size: 12))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A glass pill in the header while an update is waiting.
struct UpdateBadgeButton: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        if let available = model.updates.available {
            Button {
                model.showingUpdate = true
            } label: {
                Label(String(localized: "Update to \(available.manifest.version)"), systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.accentGradient))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(String(localized: "DeskDrop \(available.manifest.version) is available from a colleague"))
            .accessibilityIdentifier("updateBadge")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}
