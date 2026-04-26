import SwiftUI

struct SettingsView: View {
    @AppStorage("showTutorial") private var showTutorial: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show Tutorial on Startup", isOn: $showTutorial)
                } footer: {
                    Text("When enabled, the setup guide will appear each time you start the proxy server.")
                }

                Section {
                    Link(destination: URL(string: "https://github.com/africamonkey/HttpRelay")!) {
                        Text("Github Repository")
                    }
                    NavigationLink(destination: AboutView()) {
                        Text("About")
                    }
                }
            }
            .navigationTitle("Settings")
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
    NavigationStack {
        SettingsView()
    }
}
