import SwiftUI

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

    var body: some View {
        NavigationStack {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle("Enable Relay", isOn: Binding(
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
                            } catch {
                                errorMessage = "Failed to start proxy: \(error.localizedDescription)"
                                isRunning = false
                            }
                        } else {
                            proxyServer?.stop()
                            proxyServer = nil
                            isRunning = false
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
                            Text("Conn:")
                                .foregroundColor(.secondary)
                            Text("\(connectionCount)")
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            Text("Logs")
                .font(.headline)
                .padding(.top)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(logStore.entries) { entry in
                        Text(entry.displayString)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxHeight: 300)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("HttpRelay")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: clearLogs) {
                    Label("Clear Logs", systemImage: "trash")
                }
                .disabled(isRunning)
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
        }
    }



    private func clearLogs() {
        logStore.clear()
    }
}

#Preview {
    ContentView()
}
