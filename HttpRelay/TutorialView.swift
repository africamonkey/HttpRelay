import SwiftUI

struct TutorialView: View {
    @State private var selectedTab: Int = 0
    @Environment(\.dismiss) private var dismiss
    let localIP: String
    let port: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Platform", selection: $selectedTab) {
                    Text("Mac").tag(0)
                    Text("Windows").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                TabView(selection: $selectedTab) {
                    MacTutorialView(localIP: localIP, port: port)
                        .tag(0)
                    WindowsTutorialView(localIP: localIP, port: port)
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Tutorial")
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

struct MacTutorialView: View {
    let localIP: String
    let port: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mac HTTP Proxy Setup")
                    .font(.title2)
                    .fontWeight(.bold)

                StepRow(number: 1, title: "Open System Settings", description: "Click the Apple menu → System Settings. ")
                TutorialImage(name: "tutorial_mac_1")
                    .frame(maxWidth: .infinity)

                StepRow(number: 2, title: "Navigate to Network", description: "Select Network in the sidebar, and select your network interface (Ethernet or Wi-Fi). ")
                TutorialImage(name: "tutorial_mac_2")
                    .frame(maxWidth: .infinity)

                StepRow(number: 3, title: "Open Network Details", description: "Click the \"Detail\" button next to your connected Wi-Fi network")
                TutorialImage(name: "tutorial_mac_3")
                    .frame(maxWidth: .infinity)

                StepRow(number: 4, title: "Configure Proxy", description: "Select \"Proxies\" in the side bar, scroll down to \"HTTP Proxy\" and \"HTTPS proxy\" section:\n• Enter your iOS device IP address \(localIP)\n• Enter port \(port)")
                
                ProxyInfoBox(ip: localIP, port: port)
                
                TutorialImage(name: "tutorial_mac_4")
                    .frame(maxWidth: .infinity)

                StepRow(number: 5, title: "Save", description: "Click \"OK\" to apply the settings")

                Text("Make sure your Mac is connected to the same network as your iOS device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

struct WindowsTutorialView: View {
    let localIP: String
    let port: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Windows HTTP Proxy Setup")
                    .font(.title2)
                    .fontWeight(.bold)

                StepRow(number: 1, title: "Open Settings", description: "Right-click Start Menu to open Settings")
                TutorialImage(name: "tutorial_windows_1")
                    .frame(maxWidth: .infinity)

                StepRow(number: 2, title: "Navigate to Proxy", description: "Go to Network & Internet → Proxy")
                TutorialImage(name: "tutorial_windows_2")
                    .frame(maxWidth: .infinity)

                StepRow(number: 3, title: "Configure Manual Proxy", description: "Under \"Manual proxy setup\":\n• Toggle \"Set up\"")
                TutorialImage(name: "tutorial_windows_3")
                    .frame(maxWidth: .infinity)

                StepRow(number: 4, title: "Configure Manual Proxy", description: "Under \"Edit proxy server\":\n• Toggle \"ON\"\n• Enter your iOS device IP address \(localIP)\n• Enter port \(port).")
                ProxyInfoBox(ip: localIP, port: port)
                TutorialImage(name: "tutorial_windows_4")
                    .frame(maxWidth: .infinity)

                StepRow(number: 5, title: "Save", description: "Click \"Save\" to apply the settings")
                
                Text("Make sure your PC is connected to the same network as your iOS device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("For system-wide proxy, enable \"Proxy\" in Windows Settings. For browser-only proxy, use browser settings instead.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

struct StepRow: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.blue))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct TutorialImage: View {
    let name: String

    var body: some View {
        Image(name)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .cornerRadius(8)
    }
}

struct ProxyInfoBox: View {
    let ip: String
    let port: String

    var body: some View {
        HStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Server IP")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(ip)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
            Divider()
                .frame(height: 40)
            VStack(spacing: 4) {
                Text("Port")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(port)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    TutorialView(localIP: "192.168.1.100", port: "10808")
}
