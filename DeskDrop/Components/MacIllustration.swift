import SwiftUI

/// A minimal drawing of a Mac: a display on a stand, or a laptop. The screen shows
/// the owner's profile photo (or initials) and lights up when the Mac is
/// available or targeted.
struct MacIllustration: View {
    enum Glow: Equatable {
        case off
        case on
        case local
        case targeted
    }

    let kind: DeviceKind
    let initials: String
    var glow: Glow = .off
    var photo: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            screen
            if kind == .desktop { stand } else { laptopBase }
        }
        .animation(Theme.Motion.snappy, value: glow)
        .accessibilityHidden(true)
    }

    private var screen: some View {
        let outer = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack {
            outer.fill(glow == .off ? Theme.bezel : Theme.bezelLit)
            inner
                .fill(screenFill)
                .overlay(inner.fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)))
                .padding(3.5)
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: screenSize.width - 7, height: screenSize.height - 7)
                    .clipShape(inner)
                    .opacity(glow == .off ? 0.55 : 1)
                    .overlay(inner.fill(Theme.accent.opacity(glow == .targeted ? 0.55 : 0)))
            }
            if glow == .targeted {
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            } else if photo == nil {
                Text(initials.isEmpty ? "·" : initials)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(glow == .off ? 0.4 : 0.92))
                    .transition(.opacity)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .shadow(color: glowColor, radius: glow == .targeted ? 20 : 10)
    }

    private var screenSize: CGSize {
        kind == .desktop ? CGSize(width: 88, height: 60) : CGSize(width: 84, height: 56)
    }

    private var screenFill: AnyShapeStyle {
        switch glow {
        case .off:
            AnyShapeStyle(Theme.screenOff)
        case .on:
            AnyShapeStyle(LinearGradient(colors: [Theme.accent.opacity(0.85), Theme.violet.opacity(0.80)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
        case .local:
            AnyShapeStyle(LinearGradient(colors: [Theme.cyan.opacity(0.65), Theme.accent.opacity(0.75)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
        case .targeted:
            AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private var glowColor: Color {
        switch glow {
        case .off: .clear
        case .on: Theme.accent.opacity(0.22)
        case .local: Theme.cyan.opacity(0.18)
        case .targeted: Theme.accent.opacity(0.6)
        }
    }

    private var stand: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(glow == .off ? Theme.bezel : Theme.bezelLit)
                .frame(width: 14, height: 10)
            Capsule()
                .fill(glow == .off ? Theme.bezel : Theme.bezelLit)
                .frame(width: 48, height: 5)
        }
    }

    private var laptopBase: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4, style: .continuous)
            .fill(glow == .off ? Theme.bezel : Theme.bezelLit)
            .frame(width: 104, height: 6)
            .overlay(alignment: .top) {
                Capsule().fill(.black.opacity(0.18)).frame(width: 18, height: 2)
            }
            .padding(.top, 1)
            .padding(.bottom, 9)
    }
}
