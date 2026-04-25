import SwiftUI

struct TutorialView: View {
    @State private var selectedTab: Int = 0

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
                    MacTutorialView()
                        .tag(0)
                    WindowsTutorialView()
                        .tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                    }
                }
            }
        }
    }
}

struct MacTutorialView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mac HTTP Proxy Setup")
                    .font(.title2)
                    .fontWeight(.bold)

                StepRow(number: 1, title: "Open System Settings", description: "Click the Apple menu → System Settings")

                StepRow(number: 2, title: "Navigate to Wi-Fi", description: "Select Wi-Fi in the sidebar")

                StepRow(number: 3, title: "Open Network Details", description: "Click the info icon (ℹ) next to your connected Wi-Fi network")

                StepRow(number: 4, title: "Configure Proxy", description: "Scroll down to \"HTTP Proxy\" section:\n• Select \"Manual\"\n• Enter server IP address above\n• Enter port 10808 (or your configured port)")

                StepRow(number: 5, title: "Save", description: "Click \"Done\" to apply the settings")

                ImagePlaceholder(title: "Mac Network Settings Screenshot")

                Text("Note: Make sure your Mac is connected to the same network as your iOS device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

struct WindowsTutorialView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Windows HTTP Proxy Setup")
                    .font(.title2)
                    .fontWeight(.bold)

                StepRow(number: 1, title: "Open Settings", description: "Press Win + I to open Settings")

                StepRow(number: 2, title: "Navigate to Proxy", description: "Go to Network & Internet → Proxy")

                StepRow(number: 3, title: "Configure Manual Proxy", description: "Under \"Manual proxy setup\":\n• Toggle \"ON\"\n• Enter the server IP address shown above\n• Enter port 10808 (or your configured port)")

                StepRow(number: 4, title: "Save", description: "Settings are applied automatically")

                ImagePlaceholder(title: "Windows Proxy Settings Screenshot")

                Text("Note: For system-wide proxy, enable \"Proxy\" in Windows Settings. For browser-only proxy, use browser settings instead.")
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

struct ImagePlaceholder: View {
    let title: String

    var body: some View {
        VStack {
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundColor(.gray)
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    TutorialView()
}