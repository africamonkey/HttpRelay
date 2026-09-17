import Foundation
import UIKit

@MainActor
final class BackgroundKeepaliveCoordinator {
    static let shared = BackgroundKeepaliveCoordinator()

    private var taskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func start() {
        guard ProxyServer.shared?.isRunning == true else { return }
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "HttpRelay.Keepalive") { [weak self] in
            self?.expire()
        }
    }

    func stop() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }

    private func expire() {
        stop()
        ProxyServer.shared?.stop()
    }
}