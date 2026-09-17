import Foundation
import Combine
import SwiftUI

@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var activeConnections: Int = 0
    @Published private(set) var totalTxBytes: Int64 = 0
    @Published private(set) var totalRxBytes: Int64 = 0

    @Published private(set) var searchText: String = "" {
        didSet { if searchText != oldValue { recomputeFilteredEntries() } }
    }
    @Published private(set) var selectedMethods: Set<LogEntry.HTTPMethod> = [] {
        didSet { if selectedMethods != oldValue { recomputeFilteredEntries() } }
    }
    @Published private(set) var selectedStatusFilters: Set<String> = [] {
        didSet { if selectedStatusFilters != oldValue { recomputeFilteredEntries() } }
    }

    @Published private(set) var filteredEntries: [LogEntry] = []

    private var pendingTxDelta: Int = 0
    private var pendingRxDelta: Int = 0
    private var pendingPerEntryTx: [UUID: Int] = [:]
    private var pendingPerEntryRx: [UUID: Int] = [:]
    private var flushScheduled = false

    private func recomputeFilteredEntries() {
        filteredEntries = entries.filter { entry in
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

    func setSearchText(_ s: String) {
        searchText = s
    }

    func toggleMethod(_ method: LogEntry.HTTPMethod) {
        if selectedMethods.contains(method) {
            selectedMethods.remove(method)
        } else {
            selectedMethods.insert(method)
        }
    }

    func toggleStatusFilter(_ filter: String) {
        if selectedStatusFilters.contains(filter) {
            selectedStatusFilters.remove(filter)
        } else {
            selectedStatusFilters.insert(filter)
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
        recomputeFilteredEntries()
        return newEntry
    }

    func updateEntry(_ entry: LogEntry, responseStatusCode: Int, responseHeaders: [String: String]?, duration: TimeInterval) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].responseStatusCode = responseStatusCode
            entries[index].responseHeaders = responseHeaders
            entries[index].duration = duration
            recomputeFilteredEntries()
        }
    }

    func completeEntry(_ entry: LogEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].status = .completed
            if entries[index].duration == nil {
                entries[index].duration = Date().timeIntervalSince(entries[index].timestamp)
            }
            recomputeFilteredEntries()
        }
    }

    func failEntry(_ entry: LogEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].status = .failed
            if entries[index].duration == nil {
                entries[index].duration = Date().timeIntervalSince(entries[index].timestamp)
            }
            recomputeFilteredEntries()
        }
    }

    func addTxBytes(_ count: Int, to entry: LogEntry? = nil) {
        pendingTxDelta += count
        if let entry = entry {
            pendingPerEntryTx[entry.id, default: 0] += count
        }
        scheduleBytesFlush()
    }

    func addRxBytes(_ count: Int, to entry: LogEntry? = nil) {
        pendingRxDelta += count
        if let entry = entry {
            pendingPerEntryRx[entry.id, default: 0] += count
        }
        scheduleBytesFlush()
    }

    private func scheduleBytesFlush() {
        if flushScheduled { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.flushPendingBytes()
        }
    }

    private func flushPendingBytes() {
        let tx = pendingTxDelta; pendingTxDelta = 0
        let rx = pendingRxDelta; pendingRxDelta = 0
        let perTx = pendingPerEntryTx
        let perRx = pendingPerEntryRx
        pendingPerEntryTx.removeAll(keepingCapacity: true)
        pendingPerEntryRx.removeAll(keepingCapacity: true)
        flushScheduled = false
        if tx > 0 { totalTxBytes += Int64(tx) }
        if rx > 0 { totalRxBytes += Int64(rx) }
        if perTx.isEmpty && perRx.isEmpty { return }
        for i in entries.indices {
            let id = entries[i].id
            let dtx = perTx[id] ?? 0
            let drx = perRx[id] ?? 0
            if dtx != 0 || drx != 0 {
                entries[i].txBytes += Int64(dtx)
                entries[i].rxBytes += Int64(drx)
            }
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
        recomputeFilteredEntries()
    }

    func clearFilters() {
        searchText = ""
        selectedMethods = []
        selectedStatusFilters = []
    }
}
