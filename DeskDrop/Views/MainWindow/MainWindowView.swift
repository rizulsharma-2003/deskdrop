import SwiftUI

/// The main DeskDrop window. Renders immediately; nothing here waits on the network.
struct MainWindowView: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            if let banner = model.banner {
                BannerView(banner: banner,
                           onAction: { model.performBannerAction($0) },
                           onDismiss: { model.banner = nil })
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            switch model.mainSection {
            case .nearby:
                NearbyView()
                    .transition(.opacity)
            case .messages:
                MessagesView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.gentle, value: model.mainSection)
        .ignoresSafeArea(.container, edges: .top)
        .animation(Theme.Motion.spring, value: model.banner)
        .frame(minWidth: 780, minHeight: 540)
        .background(StageBackground().ignoresSafeArea())
        .animation(Theme.Motion.spring, value: model.updates.available?.manifest.version)
        .sheet(isPresented: Binding(get: { model.showingUpdate }, set: { model.showingUpdate = $0 })) {
            UpdateSheet()
        }
    }
}
