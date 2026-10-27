import SwiftUI

/// Shown beside your own Mac when nobody else is around, with the next step that
/// fits the actual reason.
struct EmptyStateView: View {
    let status: NetworkStatus

    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                if status.isSearching && !reduceMotion {
                    SearchRings()
                }
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.color(for: status.tone == .neutral ? .active : status.tone))
            }
            .frame(width: 44, height: 44)
            .background(Circle().fill(Theme.surface))
            .overlay(Circle().strokeBorder(Theme.hairline))

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityIdentifier("emptyStateTitle")
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                actions
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .glassBackground(cornerRadius: Theme.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emptyState")
    }

    private var symbol: String {
        switch status {
        case .paused: "pause.circle"
        case .permissionRequired: "lock.shield"
        case .unavailable: "wifi.slash"
        case .discovering, .connecting: "dot.radiowaves.left.and.right"
        default: "person.2"
        }
    }

    private var title: String {
        switch status {
        case .paused: String(localized: "Sharing is turned off")
        case .permissionRequired: String(localized: "DeskDrop needs local network access")
        case .unavailable: String(localized: "No network connection")
        case .discovering, .connecting: String(localized: "Looking for colleagues…")
        default: String(localized: "No colleagues nearby yet")
        }
    }

    private var message: String {
        switch status {
        case .paused:
            String(localized: "Turn sharing on so nearby colleagues can find you and send you files.")
        case .permissionRequired:
            String(localized: "Open System Settings › Privacy & Security › Local Network and turn on DeskDrop. Then come back and refresh.")
        case .unavailable:
            String(localized: "Connect to Wi‑Fi or Ethernet. DeskDrop picks up again automatically.")
        case .discovering, .connecting:
            String(localized: "DeskDrop finds Macs running DeskDrop on the same network. This usually takes a few seconds.")
        default:
            String(localized: "Ask colleagues to open DeskDrop and allow local network access when macOS asks. Everyone needs to be on the same Wi‑Fi or office network.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .paused:
            Button("Turn On Sharing") { model.setSharingEnabled(true) }
                .buttonStyle(PrimaryButtonStyle())
        case .permissionRequired:
            Button("Open Privacy Settings") { NetworkPermissions.openLocalNetworkSettings() }
                .buttonStyle(PrimaryButtonStyle())
            Button("Refresh") { model.refresh() }
                .buttonStyle(SecondaryButtonStyle())
        case .discovering, .connecting:
            EmptyView()
        default:
            Button("Refresh") { model.refresh() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("refreshButton")
            Button("Check Permission") { NetworkPermissions.openLocalNetworkSettings() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// Two soft rings expanding outwards while DeskDrop searches.
private struct SearchRings: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                    .scaleEffect(expanded ? 1.9 : 0.9)
                    .opacity(expanded ? 0 : 1)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(index) * 1.2),
                               value: expanded)
            }
        }
        .onAppear { expanded = true }
    }
}
