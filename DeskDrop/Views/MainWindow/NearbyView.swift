import SwiftUI

/// Nearby inside the main window, laid out like Messages: a floating glass
/// sidebar of transfers and recent activity beside the stage of nearby Macs.
struct NearbyView: View {
    var body: some View {
        HStack(spacing: 10) {
            ActivitySidebarView()
                .frame(width: 290)
                .sidebarGlass()
            DeskStageView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StagePaneBackground())
                .contentPane()
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// The stage's backdrop: the same surface as an open conversation, with two
/// faint pools of light for the glass cards to pick up.
private struct StagePaneBackground: View {
    var body: some View {
        ZStack {
            Theme.chatBackground
            RadialGradient(colors: [Theme.accent.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Theme.violet.opacity(0.09), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 480)
        }
    }
}
