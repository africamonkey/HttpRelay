import SwiftUI
import UIKit
import Combine

struct ContentView: View {
    @State private var isRunning = false
    @StateObject private var logStore = LogStore()
    @StateObject private var proxyServerHolder = ProxyServerHolder()
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

    /// Heights of the blocks around the log console. They are measured so the
    /// log console can take whatever height is left over on the current screen,
    /// instead of relying on a hard-coded value. Every measurement is tagged
    /// with the layout it belongs to, so a measurement taken in one layout can
    /// never be used by the other.
    @State private var topBlockHeight: BlockHeight = .none
    @State private var bottomBlockHeight: BlockHeight = .none

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    layout(viewportWidth: proxy.size.width, viewportHeight: proxy.size.height)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .onPreferenceChange(TopBlockHeightKey.self) { topBlockHeight = $0 }
                .onPreferenceChange(BottomBlockHeightKey.self) { bottomBlockHeight = $0 }
            }
            .onChange(of: proxyServerHolder.server?.failureMessage ?? nil) { newValue in
                guard let newValue else { return }
                ProxyServer.shared = nil
                BackgroundKeepaliveCoordinator.shared.stop()
                resetRunningState()
                errorMessage = newValue
            }
            .onChange(of: proxyServerHolder.server?.isRunning ?? false) { newValue in
                if newValue {
                    // The server is up. The setup guide is presented now
                    // rather than while the user is tapping the toggle: it is
                    // an expensive sheet to build, and the toggle should
                    // respond instantly.
                    if showTutorialOnStart {
                        showTutorial = true
                    }
                } else if isRunning {
                    resetRunningState()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "HTTP Debugger")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gear")
                    }
                }
            }
            .onChange(of: logStore.entries.count) { _ in
                connectionCount = logStore.activeConnections
            }
            .onChange(of: logStore.totalTxBytes) { newValue in
                txBytes = newValue
            }
            .onChange(of: logStore.totalRxBytes) { newValue in
                rxBytes = newValue
            }
            .alert("Error", isPresented: errorBinding) {
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

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: - Layout

    @ViewBuilder
    private func layout(viewportWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        if ContentLayout.isWide(windowWidth: viewportWidth) {
            wideLayout(viewportHeight: viewportHeight)
        } else {
            narrowLayout(viewportHeight: viewportHeight)
        }
    }

    /// Single column layout, used when the window is not wide enough for a
    /// sidebar next to the log console.
    private func narrowLayout(viewportHeight: CGFloat) -> some View {
        let reserved = narrowTopHeight + narrowBottomHeight
            + 2 * ContentLayout.blockSpacing
            + 2 * ContentLayout.layoutPadding
        let consoleHeight = ContentLayout.logHeight(windowHeight: viewportHeight, reservedHeight: reserved)
        return VStack(alignment: .leading, spacing: ContentLayout.blockSpacing) {
            VStack(alignment: .leading, spacing: ContentLayout.blockSpacing) {
                toggleCard
                statusCard
                filterBar
            }
            .background(heightReader(TopBlockHeightKey.self, layout: .narrow))

            logsList(height: consoleHeight)

            requestsFooter
                .background(heightReader(BottomBlockHeightKey.self, layout: .narrow))
        }
        .padding(ContentLayout.layoutPadding)
    }

    /// Two column layout: controls on the left, log console on the right.
    /// Used on wide windows such as the unfolded iPhone Duo and iPad.
    private func wideLayout(viewportHeight: CGFloat) -> some View {
        let reserved = wideTopHeight
            + ContentLayout.blockSpacing
            + 2 * ContentLayout.layoutPadding
        let consoleHeight = ContentLayout.logHeight(windowHeight: viewportHeight, reservedHeight: reserved)
        return HStack(alignment: .top, spacing: ContentLayout.blockSpacing) {
            VStack(alignment: .leading, spacing: ContentLayout.blockSpacing) {
                toggleCard
                stackedStatusCard
                requestsFooter
            }
            .frame(width: ContentLayout.sidebarWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: ContentLayout.blockSpacing) {
                filterBar
                    .background(heightReader(TopBlockHeightKey.self, layout: .wide))

                logsList(height: consoleHeight)
            }
            .frame(minWidth: ContentLayout.minLogColumnWidth, alignment: .top)
        }
        .padding(ContentLayout.layoutPadding)
    }

    private var narrowTopHeight: CGFloat {
        topBlockHeight.layout == .narrow ? topBlockHeight.height : 0
    }

    private var narrowBottomHeight: CGFloat {
        bottomBlockHeight.layout == .narrow ? bottomBlockHeight.height : 0
    }

    private var wideTopHeight: CGFloat {
        topBlockHeight.layout == .wide ? topBlockHeight.height : 0
    }

    /// The log console.
    ///
    /// It takes the space that is left over once the blocks around it are
    /// laid out, and scrolls on its own. The page around it scrolls as well,
    /// but only when the window is too short to hold all of it.
    private func logsList(height: CGFloat) -> some View {
        ScrollView {
            logRows
        }
        .frame(height: height)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var logRows: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(logStore.filteredEntries) { entry in
                LogRowView(entry: entry)
                    .onTapGesture {
                        if let updatedEntry = logStore.entries.first(where: { $0.id == entry.id }) {
                            selectedEntry = updatedEntry
                        }
                    }
            }
        }
    }

    private func heightReader<K: PreferenceKey>(_ key: K.Type, layout: BlockHeight.Layout) -> some View where K.Value == BlockHeight {
        GeometryReader { geo in
            Color.clear.preference(key: key, value: BlockHeight(layout: layout, height: geo.size.height))
        }
    }

    // MARK: - Blocks

    private var toggleCard: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { isRunning },
                set: { newValue in toggleProxy(newValue) }
            )) {
                Text("Enable Debugger Server")
                    .lineLimit(1)
            }
            .toggleStyle(SwitchToggleStyle(tint: .green))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var statusCard: some View {
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
                    portField
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
    }

    /// Same information as `statusCard`, stacked into a single column so it
    /// fits in the sidebar of the two column layout.
    private var stackedStatusCard: some View {
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
            portField
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
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private var portField: some View {
        HStack {
            Text("Port:")
                .foregroundColor(.secondary)
            TextField("Port", text: $portString)
                .keyboardType(.numberPad)
                .frame(width: 80)
                .disabled(isRunning)
        }
    }

    private var requestsFooter: some View {
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

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search host/path...", text: Binding(
                    get: { logStore.searchText },
                    set: { logStore.setSearchText($0) }
                ))
                .textFieldStyle(.plain)

                if !logStore.searchText.isEmpty {
                    Button(action: { logStore.setSearchText("") }) {
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
                            logStore.toggleMethod(method)
                        }
                    }

                    Divider()
                        .frame(height: 20)

                    ForEach(["2xx", "3xx", "4xx", "5xx"], id: \.self) { status in
                        FilterChip(
                            title: status,
                            isSelected: logStore.selectedStatusFilters.contains(status)
                        ) {
                            logStore.toggleStatusFilter(status)
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

    private func clearLogs() {
        logStore.clear()
    }

    /// Puts the screen back into the "stopped" state.
    ///
    /// Every way out of "running" goes through here: the user switching the
    /// toggle off, the server failing to start, and the server stopping on
    /// its own. Otherwise the uptime timer would keep running and the
    /// device would never lock itself.
    private func resetRunningState() {
        isRunning = false
        startTime = nil
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func toggleProxy(_ newValue: Bool) {
        if newValue {
            let port = UInt16(portString) ?? 10808
            let server = ProxyServer(port: port, logStore: logStore)
            proxyServerHolder.attach(server)
            ProxyServer.shared = server
            server.onLocalIPReady = { ip in
                localIP = ip
            }

            // The UI reacts immediately. The listener itself is created on a
            // background queue, because creating the first listener of a
            // process takes tens of milliseconds.
            isRunning = true
            startTime = Date()
            uptimeString = "00:00:00"
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                if let start = startTime {
                    let elapsed = Int(Date().timeIntervalSince(start))
                    let hours = elapsed / 3600
                    let minutes = (elapsed % 3600) / 60
                    let seconds = elapsed % 60
                    uptimeString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
                }
            }
            UIApplication.shared.isIdleTimerDisabled = true

            // The run is registered here, on the main thread, so that a
            // switch-off while the listener is being created wins over the
            // pending start.
            let runID = server.beginRun()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try server.start(runID: runID)
                } catch {
                    DispatchQueue.main.async {
                        ProxyServer.shared = nil
                        BackgroundKeepaliveCoordinator.shared.stop()
                        self.resetRunningState()
                        self.errorMessage = "Failed to start debugger: \(error.localizedDescription)"
                    }
                }
            }
        } else {
            proxyServerHolder.server?.stop()
            ProxyServer.shared = nil
            proxyServerHolder.detach()
            resetRunningState()
        }
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
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.formattedTime)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

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

/// Holds the running proxy server.
///
/// The holder republishes the server's changes: reading
/// `holder.server?.isRunning` in a view body only subscribes the view to
/// the holder, not to the server, so without the forwarding the
/// `onChange` handlers would only fire when something else happened to
/// re-evaluate the body.
final class ProxyServerHolder: ObservableObject {
    @Published var server: ProxyServer?
    private var serverChanges: AnyCancellable?

    func attach(_ newServer: ProxyServer?) {
        server = newServer
        serverChanges = newServer?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func detach() {
        serverChanges = nil
        server = nil
    }
}

/// Height of a block of the layout, tagged with the layout it was measured in.
///
/// The main screen has two layouts. A measurement is only valid for the layout
/// it was taken in, so the tag keeps a measurement of one layout from being
/// used by the other while the window is being resized.
private struct BlockHeight: Equatable {
    enum Layout: Int {
        case narrow
        case wide
    }

    let layout: Layout?
    let height: CGFloat

    static let none = BlockHeight(layout: nil, height: 0)

    /// Keeps the tallest measurement of the same layout. A measurement of a
    /// different layout replaces this one, it is never added to it.
    func merged(with next: BlockHeight) -> BlockHeight {
        guard let nextLayout = next.layout else { return self }
        guard layout == .some(nextLayout) else { return next }
        return BlockHeight(layout: nextLayout, height: max(height, next.height))
    }
}

/// Height of the block that sits above the log console.
private struct TopBlockHeightKey: PreferenceKey {
    static var defaultValue = BlockHeight.none
    static func reduce(value: inout BlockHeight, nextValue: () -> BlockHeight) {
        value = value.merged(with: nextValue())
    }
}

/// Height of the block that sits below the log console.
private struct BottomBlockHeightKey: PreferenceKey {
    static var defaultValue = BlockHeight.none
    static func reduce(value: inout BlockHeight, nextValue: () -> BlockHeight) {
        value = value.merged(with: nextValue())
    }
}
