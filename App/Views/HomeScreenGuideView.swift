import SwiftUI
import UIKit
import VMCore

/// Explains the two ways to put a virtual machine on the Home Screen:
/// as an app-like icon (a Shortcuts bookmark) or as a widget.
struct HomeScreenGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let config: VMConfiguration

    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        MachineIcon(osType: config.osType, size: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(config.name).font(.headline)
                            Text("Opens PocketVM and starts this machine.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    step(1, "Open the **Shortcuts** app and tap **+**.")
                    step(2, "Tap **Add Action**, search for **PocketVM** and choose **Start Virtual Machine**.")
                    step(3, "Tap **Virtual Machine** in the action and pick **\(config.name)**.")
                    step(4, "Tap the share button (or the name at the top) and choose **Add to Home Screen**. Pick a name and an icon, then tap **Add**.")
                    Button {
                        if let url = URL(string: "shortcuts://create-shortcut") { openURL(url) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                    }
                } header: {
                    Text("App Icon")
                } footer: {
                    Text("The icon looks and works like a separate app for this machine. Siri also understands “Start \(config.name) in PocketVM”.")
                }

                Section {
                    step(1, "Touch and hold an empty spot on the Home Screen until the icons jiggle, then tap **Edit › Add Widget**.")
                    step(2, "Search for **PocketVM** and add the **Virtual Machine** widget.")
                    step(3, "Touch and hold the widget, tap **Edit Widget** and choose **\(config.name)**.")
                } header: {
                    Text("Widget")
                } footer: {
                    Text("Add one widget per machine. Tapping it starts the machine.")
                }

                Section {
                    Button {
                        UIPasteboard.general.url = MachineCatalog.startURL(for: config.id)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Start Link", systemImage: copied ? "checkmark" : "link")
                    }
                } footer: {
                    Text("For other automations, for example an “Open URLs” action: \(MachineCatalog.startURL(for: config.id).absoluteString)")
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Add to Home Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }
}
