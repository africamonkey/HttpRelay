import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class LogStore {
    var entries: [LogEntry] = []
    var activeConnections: Int = 0

    func log(host: String, port: Int, status: LogEntry.LogStatus) {
        entries.insert(LogEntry(timestamp: Date(), host: host, port: port, status: status), at: 0)
        if entries.count > 500 {
            entries.removeLast()
        }
    }

    func incrementConnections() {
        activeConnections += 1
    }

    func decrementConnections() {
        if activeConnections > 0 {
            activeConnections -= 1
        }
    }

    func clear() {
        entries = []
        activeConnections = 0
    }
}
