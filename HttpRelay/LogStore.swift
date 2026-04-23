import Foundation
import Observation

@Observable
final class LogStore {
    var entries: [LogEntry] = []
    var activeConnections: Int = 0

    func log(host: String, port: Int, status: LogEntry.LogStatus) {
        let entry = LogEntry(timestamp: Date(), host: host, port: port, status: status)
        entries.insert(entry, at: 0)
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
        entries.removeAll()
        activeConnections = 0
    }
}
