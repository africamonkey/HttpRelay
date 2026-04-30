import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class LogStore {
    private(set) var entries: [LogEntry] = []
    private(set) var activeConnections: Int = 0
    private(set) var totalTxBytes: Int64 = 0
    private(set) var totalRxBytes: Int64 = 0

    var searchText: String = ""
    var selectedMethods: Set<LogEntry.HTTPMethod> = []
    var selectedStatusFilters: Set<String> = []

    var filteredEntries: [LogEntry] {
        entries.filter { entry in
            let matchesSearch: Bool
            if searchText.isEmpty {
                matchesSearch = true
            } else {
                let lowercased = searchText.lowercased()
                matchesSearch = entry.host.lowercased().contains(lowercased)
                    || entry.path.lowercased().contains(lowercased)
                    || (entry.query?.lowercased().contains(lowercased) ?? false)
            }

            let matchesMethod = selectedMethods.isEmpty || selectedMethods.contains(entry.method)

            let matchesStatus: Bool
            if selectedStatusFilters.isEmpty {
                matchesStatus = true
            } else {
                if let category = entry.statusCodeCategory {
                    matchesStatus = selectedStatusFilters.contains(category)
                } else {
                    matchesStatus = false
                }
            }

            return matchesSearch && matchesMethod && matchesStatus
        }
    }

    func log(host: String, port: Int, path: String, query: String?, method: LogEntry.HTTPMethod, requestHeaders: [String: String]) -> LogEntry {
        let newEntry = LogEntry(
            timestamp: Date(),
            host: host,
            port: port,
            path: path,
            query: query,
            method: method,
            requestHeaders: requestHeaders,
            responseStatusCode: nil,
            responseHeaders: nil,
            txBytes: 0,
            rxBytes: 0,
            duration: nil
        )
        if entries.count >= 500 {
            entries = [newEntry] + entries.dropLast()
        } else {
            entries = [newEntry] + entries
        }
        return newEntry
    }

    func updateEntry(_ entry: LogEntry, responseStatusCode: Int, responseHeaders: [String: String]?, duration: TimeInterval) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].responseStatusCode = responseStatusCode
            entries[index].responseHeaders = responseHeaders
            entries[index].duration = duration
        }
    }

    func completeEntry(_ entry: LogEntry) {
    }

    func failEntry(_ entry: LogEntry) {
    }

    func addTxBytes(_ count: Int, to entry: LogEntry? = nil) {
        totalTxBytes += Int64(count)
        if let entry = entry, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var updated = entries[index]
            updated.txBytes += Int64(count)
            entries[index] = updated
        }
    }

    func addRxBytes(_ count: Int, to entry: LogEntry? = nil) {
        totalRxBytes += Int64(count)
        if let entry = entry, let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var updated = entries[index]
            updated.rxBytes += Int64(count)
            entries[index] = updated
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
        totalTxBytes = 0
        totalRxBytes = 0
        searchText = ""
        selectedMethods = []
        selectedStatusFilters = []
    }

    func clearFilters() {
        searchText = ""
        selectedMethods = []
        selectedStatusFilters = []
    }
}
