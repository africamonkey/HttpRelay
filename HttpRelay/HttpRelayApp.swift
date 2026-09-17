import SwiftUI

@main
struct HttpRelayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                BackgroundKeepaliveCoordinator.shared.start()
            case .active:
                BackgroundKeepaliveCoordinator.shared.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
