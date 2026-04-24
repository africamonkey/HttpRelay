import SwiftUI

struct ContentView: View {
    @State private var isRunning = false
    @State private var logStore = LogStore()
    @State private var proxyServer: ProxyServer?
    @State private var connectionCount: Int = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Toggle("Proxy", isOn: Binding(
                    get: { isRunning },
                    set: { newValue in
                        if newValue {
                            proxyServer = ProxyServer(port: 10808, logStore: logStore)
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
                    Text("Status:")
                        .foregroundColor(.secondary)
                    Text(isRunning ? "Running" : "Stopped")
                        .fontWeight(.medium)
                }

                HStack {
                    Text("Port:")
                        .foregroundColor(.secondary)
                    Text("10808")
                }

                HStack {
                    Text("Connections:")
                        .foregroundColor(.secondary)
                    Text("\(connectionCount)")
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