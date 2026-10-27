import AppKit
import SwiftUI

/// Design tokens shared by every view: colors, radii, spacing and motion.
enum Theme {
    static let accent = Color(red: 0.30, green: 0.56, blue: 1.00)
    static let violet = Color(red: 0.56, green: 0.43, blue: 1.00)
    static let cyan = Color(red: 0.32, green: 0.82, blue: 0.96)
    static let pink = Color(red: 1.00, green: 0.45, blue: 0.78)
    static let success = Color(red: 0.27, green: 0.80, blue: 0.53)
    static let warning = Color(red: 1.00, green: 0.70, blue: 0.28)
    static let danger = Color(red: 1.00, green: 0.42, blue: 0.40)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let backgroundTop = Color.dynamic(light: 0xF6F7FA, dark: 0x17181E)
    static let backgroundBottom = Color.dynamic(light: 0xE9EBF0, dark: 0x0C0D11)
    static let surface = Color.dynamic(light: (0xFFFFFF, 0.70), dark: (0xFFFFFF, 0.045))
    static let surfaceHover = Color.dynamic(light: (0xFFFFFF, 0.92), dark: (0xFFFFFF, 0.075))
    static let hairline = Color.dynamic(light: (0x000000, 0.08), dark: (0xFFFFFF, 0.08))
    static let hairlineStrong = Color.dynamic(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.16))
    static let shadow = Color.dynamic(light: (0x1B2233, 0.10), dark: (0x000000, 0.40))
    static let screenOff = Color.dynamic(light: 0x2E323D, dark: 0x22252D)
    static let bezel = Color.dynamic(light: 0xA9AFBC, dark: 0x5A6070)
    static let bezelLit = Color.dynamic(light: 0x8C93A3, dark: 0x8E97B0)

    // Messages
    static let messageBlue = Color.dynamic(light: 0x007AFF, dark: 0x0A84FF)
    static let incomingBubble = Color.dynamic(light: 0xE9E9EB, dark: 0x3B3B3D)
    static let chatBackground = Color.dynamic(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let chatSidebar = Color.dynamic(light: 0xF4F4F6, dark: 0x262628)
    static let chatField = Color.dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)

    enum Radius {
        static let card: CGFloat = 22
        static let panel: CGFloat = 16
        static let row: CGFloat = 12
        static let control: CGFloat = 9
    }

    enum Motion {
        static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
        static let gentle = Animation.easeInOut(duration: 0.22)
        static let flightDuration: Double = 0.85
    }

    static func color(for tone: NetworkStatus.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .active: accent
        case .success: success
        case .warning: warning
        case .danger: danger
        }
    }
}

extension Color {
    /// A color that follows the effective appearance of whatever draws it.
    static func dynamic(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        let (lightHex, lightAlpha) = light
        let (darkHex, darkAlpha) = dark
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: darkHex, alpha: darkAlpha) : NSColor(hex: lightHex, alpha: lightAlpha)
        })
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(light: (light, 1), dark: (dark, 1))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// The window backdrop: deep charcoal with two faint, static pools of light.
struct StageBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.violet.opacity(0.10), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.accent.opacity(0.07), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
        }
    }
}
