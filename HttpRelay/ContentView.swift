import SwiftUI

struct ContentView: View {
    @State private var isRunning = false
    @State private var logStore = LogStore()
    @State private var proxyServer: ProxyServer?
    @State private var connectionCount: Int = 0

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Toggle("代理开关", isOn: Binding(
                        get: { isRunning },
                        set: { newValue in
                            if newValue {
                                proxyServer = ProxyServer(port: 10808, logStore: logStore)
                                do {
                                    try proxyServer?.start()
                                    isRunning = true
                                } catch {
                                    print("Failed to start proxy: \(error)")
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
                        Text("状态:")
                            .foregroundColor(.secondary)
                        Text(isRunning ? "运行中" : "已停止")
                            .fontWeight(.medium)
                    }

                    HStack {
                        Text("端口:")
                            .foregroundColor(.secondary)
                        Text("10808")
                    }

                    HStack {
                        Text("连接数:")
                            .foregroundColor(.secondary)
                        Text("\(connectionCount)")
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                Text("日志")
                    .font(.headline)
                    .padding(.top)

                List {
                    ForEach(logStore.entries) { entry in
                        Text(entry.displayString)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .listStyle(.plain)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
            .padding()
            .navigationTitle("HttpRelay")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: clearLogs) {
                        Label("清除日志", systemImage: "trash")
                    }
                    .disabled(isRunning)
                }
            }
        }
        .onChange(of: logStore.activeConnections) { _, newValue in
            connectionCount = newValue
        }
    }



    private func clearLogs() {
        logStore.clear()
    }
}

#Preview {
    ContentView()
}