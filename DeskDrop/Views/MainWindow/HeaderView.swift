import SwiftUI

/// App identity, live status, who you appear as, and quick access to activity and settings.
struct HeaderView: View {
    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("DeskDrop")
                .font(.system(size: 14, weight: .semibold))
            StatusPill(status: model.networkStatus)

            Spacer(minLength: 12)
            SectionSwitcher()
            Spacer(minLength: 12)

            UpdateBadgeButton()

            // Like a toolbar group: one glass capsule holding who you are and the tools.
            HStack(spacing: 2) {
                SettingsLink {
                    Label(model.settings.displayName, systemImage: model.localDeviceKind.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .frame(height: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .layoutPriority(-1)
                .help("You appear to colleagues as “\(model.settings.displayName)”. Change it in Settings.")
                .accessibilityLabel(Text("You appear as \(model.settings.displayName)"))
                .accessibilityIdentifier("localName")

                Divider().frame(height: 14)

                Button {
                    openWindow(id: SceneID.history)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(IconButtonStyle())
                .help("Recent Activity")
                .accessibilityLabel(Text("Recent Activity"))
                .accessibilityIdentifier("historyButton")

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(IconButtonStyle())
                .help("Settings")
                .accessibilityLabel(Text("Settings"))
                .accessibilityIdentifier("settingsButton")
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .liquidGlass(in: Capsule())
        }
        // Sits in the title bar, vertically centred on the window controls.
        .padding(.leading, 80)
        .padding(.trailing, 12)
        .frame(height: 40)
        .padding(.top, 2)
    }
}

/// Switches the main window between the desk of nearby Macs and Messages: a glass
/// capsule with a tinted selection that slides between the two. Messages shows
/// the unread count.
struct SectionSwitcher: View {
    @Environment(DeskDropViewModel.self) private var model
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            segment(.nearby, title: String(localized: "Nearby"), symbol: "dot.radiowaves.left.and.right",
                    identifier: "nearbyButton")
            segment(.messages, title: String(localized: "Messages"), symbol: "bubble.left.and.bubble.right",
                    identifier: "messagesButton")
        }
        .padding(3)
        .liquidGlass(in: Capsule())
        .animation(Theme.Motion.snappy, value: model.mainSection)
    }

    private func segment(_ section: DeskDropViewModel.MainSection, title: String, symbol: String,
                         identifier: String) -> some View {
        let selected = model.mainSection == section
        let unread = section == .messages ? model.unreadMessageCount : 0
        return Button {
            model.mainSection = section
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minHeight: 15)
                        .background(Capsule().fill(Theme.danger))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.75)))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                if selected {
                    Capsule()
                        .fill(Theme.accent.gradient)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 1)
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(unread > 0 ? "\(title), \(unread) unread" : title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A dismissible message under the header.
struct BannerView: View {
    let banner: AppBanner
    let onAction: (AppBanner.Action) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if let message = banner.message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let action = banner.action, let title = banner.actionTitle {
                Button(title) { onAction(action) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24))
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassBackground(cornerRadius: 14, tint: color.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banner")
    }

    private var symbol: String {
        switch banner.style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch banner.style {
        case .info: Theme.accent
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}
