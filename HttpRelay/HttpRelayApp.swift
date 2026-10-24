import SwiftUI
import Network

@main
struct HttpRelayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        warmUpNetworkFramework()
        warmUpIdleTimer()
    }

    /// The first `NWListener` a process creates has to initialise the
    /// Network framework, which takes tens of milliseconds. Doing that here,
    /// on a background queue at launch, keeps it away from the moment the
    /// user starts the debugger server.
    private func warmUpNetworkFramework() {
        DispatchQueue.global(qos: .utility).async {
            guard let listener = try? NWListener(using: .tcp, on: .any) else { return }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                listener.cancel()
            }
        }
    }

    /// The first time the app changes the idle timer flag, UIKit has to
    /// set up the machinery behind it, which takes tens of milliseconds.
    /// Paying for it at launch keeps it out of the moment the user starts
    /// the debugger server. The flag ends up where it started.
    private func warmUpIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = true
        UIApplication.shared.isIdleTimerDisabled = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
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
