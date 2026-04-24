import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class LogStore {
    private(set) var entries: [LogEntry] = []
    private(set) var activeConnections: Int = 0

    func log(host: String, port: Int, status: LogEntry.LogStatus) {
        let newEntry = LogEntry(timestamp: Date(), host: host, port: port, status: status)
        if entries.count >= 500 {
            entries = [newEntry] + entries.dropLast()
        } else {
            entries = [newEntry] + entries
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
