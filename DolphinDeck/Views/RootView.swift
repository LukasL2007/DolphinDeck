import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var bluetooth: FlipperBluetoothManager
    @State private var selectedTab = 0

    init() {
        UITabBar.appearance().tintColor = .systemOrange
        UITabBar.appearance().unselectedItemTintColor = .secondaryLabel
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label("Deck", systemImage: "square.grid.2x2.fill") }
            .tag(0)

            NavigationStack {
                FileFavoritesView()
            }
            .tabItem { Label("Favoriten", systemImage: "star.square.on.square.fill") }
            .tag(1)

            NavigationStack {
                DevicesView()
            }
            .tabItem { Label("Flipper", systemImage: "dot.radiowaves.left.and.right") }
            .tag(2)

            NavigationStack {
                RemoteControlView()
            }
            .tabItem { Label("Remote", systemImage: "gamecontroller.fill") }
            .tag(3)

            NavigationStack {
                MoreView()
            }
            .tabItem { Label("Mehr", systemImage: "ellipsis.circle.fill") }
            .tag(4)
        }
        .tint(.orange)
        .accentColor(.orange)
        .toolbarBackground(.visible, for: .tabBar)
        .onOpenURL { url in
            switch url.host {
            case "favorites": selectedTab = 1
            case "remote": selectedTab = 3
            case "run-favorite":
                selectedTab = 1
                guard let components = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false),
                    let path = components.queryItems?
                        .first(where: { $0.name == "path" })?.value,
                    !path.isEmpty else {
                    return
                }
                Task {
                    await bluetooth.executeFavorite(at: path)
                }
            default: selectedTab = 0
            }
        }
    }
}
