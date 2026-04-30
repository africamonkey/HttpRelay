import SwiftUI
import UIKit

struct ContentView: View {
    @State private var isRunning = false
    @State private var logStore = LogStore()
    @State private var proxyServer: ProxyServer?
    @State private var connectionCount: Int = 0
    @State private var errorMessage: String?
    @State private var txBytes: Int64 = 0
    @State private var rxBytes: Int64 = 0
    @State private var localIP: String = "—"
    @State private var portString: String = "10808"
    @State private var startTime: Date?
    @State private var uptimeString: String = "00:00:00"
    @State private var timer: Timer?
    @State private var showTutorial: Bool = false
    @State private var showSettings: Bool = false
    @State private var selectedEntry: LogEntry?
    @AppStorage("showTutorial") private var showTutorialOnStart: Bool = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Toggle("Enable Debugger Server", isOn: Binding(
                        get: { isRunning },
                        set: { newValue in
                            if newValue {
                                let port = UInt16(portString) ?? 10808
                                proxyServer = ProxyServer(port: port, logStore: logStore)
                                proxyServer?.onLocalIPReady = { [self] ip in
                                    localIP = ip
                                }
                                do {
                                    try proxyServer?.start()
                                    isRunning = true
                                    startTime = Date()
                                    uptimeString = "00:00:00"
                                    if showTutorialOnStart {
                                        showTutorial = true
                                    }
                                    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                                        if let start = startTime {
                                            let elapsed = Int(Date().timeIntervalSince(start))
                                            let hours = elapsed / 3600
                                            let minutes = (elapsed % 3600) / 60
                                            let seconds = elapsed % 60
                                            uptimeString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
                                        }
                                    }
                                    UIApplication.shared.isIdleTimerDisabled = true
                                } catch {
                                    errorMessage = "Failed to start debugger: \(error.localizedDescription)"
                                    isRunning = false
                                }
                            } else {
                                proxyServer?.stop()
                                proxyServer = nil
                                isRunning = false
                                startTime = nil
                                timer?.invalidate()
                                timer = nil
                                UIApplication.shared.isIdleTimerDisabled = false
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Status:")
                                    .foregroundColor(.secondary)
                                Text(isRunning ? "Running" : "Stopped")
                                    .fontWeight(.medium)
                                    .foregroundColor(isRunning ? .green : .red)
                            }
                            HStack {
                                Text("IP:")
                                    .foregroundColor(.secondary)
                                Text(localIP)
                            }
                            HStack {
                                Text("Port:")
                                    .foregroundColor(.secondary)
                                TextField("Port", text: $portString)
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)
                                    .disabled(isRunning)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack {
                                Text("TX:")
                                    .foregroundColor(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: txBytes, countStyle: .binary))
                            }
                            HStack {
                                Text("RX:")
                                    .foregroundColor(.secondary)
                                Text(ByteCountFormatter.string(fromByteCount: rxBytes, countStyle: .binary))
                            }
                            HStack {
                                Text("Uptime:")
                                    .foregroundColor(.secondary)
                                Text(uptimeString)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                filterBar

                logsList

                HStack {
                    HStack {
                        Text("Requests:")
                            .foregroundColor(.secondary)
                        Text("\(logStore.filteredEntries.count)")
                            .fontWeight(.medium)
                    }
                    Spacer()
                    Button(action: clearLogs) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .disabled(isRunning)
                }
                .padding(.top, 4)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "HTTP Debugger")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
            .onChange(of: logStore.entries.count) { _, _ in
                connectionCount = logStore.activeConnections
            }
            .onChange(of: logStore.totalTxBytes) { _, newValue in
                txBytes = newValue
            }
            .onChange(of: logStore.totalRxBytes) { _, newValue in
                rxBytes = newValue
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(isPresented: $showTutorial) {
                TutorialView(localIP: localIP, port: portString)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $selectedEntry) { entry in
                LogDetailView(entry: entry)
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search host/path...", text: $logStore.searchText)
                    .textFieldStyle(.plain)

                if !logStore.searchText.isEmpty {
                    Button(action: { logStore.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LogEntry.HTTPMethod.allCases, id: \.self) { method in
                        FilterChip(
                            title: method.rawValue,
                            isSelected: logStore.selectedMethods.contains(method)
                        ) {
                            if logStore.selectedMethods.contains(method) {
                                logStore.selectedMethods.remove(method)
                            } else {
                                logStore.selectedMethods.insert(method)
                            }
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    ForEach(["2xx", "3xx", "4xx", "5xx"], id: \.self) { status in
                        FilterChip(
                            title: status,
                            isSelected: logStore.selectedStatusFilters.contains(status)
                        ) {
                            if logStore.selectedStatusFilters.contains(status) {
                                logStore.selectedStatusFilters.remove(status)
                            } else {
                                logStore.selectedStatusFilters.insert(status)
                            }
                        }
                    }

                    if !logStore.searchText.isEmpty || !logStore.selectedMethods.isEmpty || !logStore.selectedStatusFilters.isEmpty {
                        Divider()
                            .frame(height: 20)

                        Button(action: { logStore.clearFilters() }) {
                            Text("Clear")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
    }

    private var logsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(logStore.filteredEntries) { entry in
                    LogRowView(entryId: entry.id, logStore: logStore)
                        .onTapGesture {
                            if let updatedEntry = logStore.entries.first(where: { $0.id == entry.id }) {
                                selectedEntry = updatedEntry
                            }
                        }
                }
            }
        }
        .frame(maxHeight: 350)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func clearLogs() {
        logStore.clear()
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.blue : Color(.systemGray5))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(6)
        }
    }
}

struct LogRowView: View {
    let entryId: UUID
    let logStore: LogStore

    private var entry: LogEntry? {
        logStore.entries.first(where: { $0.id == entryId })
    }

    var body: some View {
        if let entry = entry {
            HStack(spacing: 8) {
                Text(entry.formattedTime)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                Text(entry.method.rawValue)
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(methodColor(for: entry.method))
                    .foregroundColor(.white)
                    .cornerRadius(4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(entry.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.formattedRxBytes)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(entry.formattedDuration)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(entry.isFailed ? Color.red.opacity(0.1) : Color.clear)
        }
    }

    private func methodColor(for method: LogEntry.HTTPMethod) -> Color {
        switch method {
        case .get: return .blue
        case .post: return .green
        case .put: return .orange
        case .delete: return .red
        case .connect: return .purple
        default: return .gray
        }
    }
}

struct LogDetailView: View {
    let entry: LogEntry
    @Environment(\.dismiss) private var dismiss

    private var methodColor: Color {
        switch entry.method {
        case .get: return .blue
        case .post: return .green
        case .put: return .orange
        case .delete: return .red
        case .connect: return .purple
        default: return .gray
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(entry.method.rawValue)
                                .font(.headline)
                                .fontWeight(.bold)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(6)

                            Spacer()

                            if let statusCode = entry.responseStatusCode {
                                Text("\(statusCode)")
                                    .font(.headline)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(statusCode >= 200 && statusCode < 300 ? Color.green : Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                            }

                            Text(entry.formattedDuration)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Text(entry.fullURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("REQUEST HEADERS")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.secondary)

                        ForEach(Array(entry.requestHeaders.keys.sorted()), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text(key + ":")
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                                    .frame(width: 120, alignment: .leading)

                                Text(entry.requestHeaders[key] ?? "")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    if let responseHeaders = entry.responseHeaders, !responseHeaders.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("RESPONSE HEADERS")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)

                            ForEach(Array(responseHeaders.keys.sorted()), id: \.self) { key in
                                HStack(alignment: .top) {
                                    Text(key + ":")
                                        .font(.system(.caption, design: .monospaced))
                                        .fontWeight(.medium)
                                        .foregroundColor(.green)
                                        .frame(width: 120, alignment: .leading)

                                    Text(responseHeaders[key] ?? "")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }

                    HStack {
                        VStack(alignment: .leading) {
                            Text("TX")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(entry.formattedTxBytes)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }

                        Spacer()

                        VStack(alignment: .center) {
                            Text("RX")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(entry.formattedRxBytes)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text("Time")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(entry.formattedDuration)
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("Request Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
