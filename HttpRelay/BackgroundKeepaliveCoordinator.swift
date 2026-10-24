import Foundation
import UIKit

@MainActor
final class BackgroundKeepaliveCoordinator {
    static let shared = BackgroundKeepaliveCoordinator()

    private var taskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func start() {
        // The server is asked for before it is up, so the check is on the
        // server existing at all - not on it already being ready.
        guard ProxyServer.shared != nil else { return }
        guard taskID == .invalid else { return }
        let newID = UIApplication.shared.beginBackgroundTask(withName: "HttpRelay.Keepalive") { [weak self] in
            self?.expire()
        }
        if newID == .invalid {
            print("[Keepalive] beginBackgroundTask returned .invalid; no background time granted")
            return
        }
        taskID = newID
    }

    func stop() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }

    private func expire() {
        print("[Keepalive] background task expired; stopping proxy")
        stop()
        ProxyServer.shared?.stop()
    }
}
