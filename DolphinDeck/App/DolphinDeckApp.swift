import SwiftUI

@main
struct DolphinDeckApp: App {
    @StateObject private var bluetooth = FlipperBluetoothManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bluetooth)
                .preferredColorScheme(.dark)
        }
    }
}
