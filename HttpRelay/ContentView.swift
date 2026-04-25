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

    var body: some View {
        NavigationStack {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle("Enable Proxy Server", isOn: Binding(
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
                                errorMessage = "Failed to start proxy: \(error.localizedDescription)"
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
                            Text("Up time:")
                                .foregroundColor(.secondary)
                            Text(uptimeString)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button(action: clearLogs) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .disabled(isRunning)
            }
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
        .navigationTitle(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "Relay")
        .toolbar {
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
