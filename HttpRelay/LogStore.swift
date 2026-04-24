import Foundation
import Observation

@Observable
@MainActor
final class LogStore {
    private var _entries: [LogEntry] = []
    private var _activeConnections: Int = 0

    var entries: [LogEntry] {
        _entries
    }

    var activeConnections: Int {
        _activeConnections
    }

    func log(host: String, port: Int, status: LogEntry.LogStatus) {
        let entry = LogEntry(timestamp: Date(), host: host, port: port, status: status)
        _entries = [entry] + _entries
        if _entries.count > 500 {
            _entries = Array(_entries.prefix(500))
        }
    }

    func incrementConnections() {
        _activeConnections += 1
    }

    func decrementConnections() {
        if _activeConnections > 0 {
            _activeConnections -= 1
        }
    }

    func clear() {
        _entries = []
        _activeConnections = 0
    }
}
