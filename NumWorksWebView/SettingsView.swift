import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            GroupBox(label: Text("Shortcut").font(.headline)) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Show / Hide Calculator")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .toggleWindow)
                        .fixedSize()
                }
                .padding(.vertical, 8)
            }

            GroupBox(label: Text("Menu Bar").font(.headline)) {
                Toggle(
                    "Show menu bar icon",
                    isOn: Binding(
                        get: { appDelegate.menuIconEnabled },
                        set: { appDelegate.setMenuIconEnabled($0) }
                    )
                )
                .padding(.vertical, 6)

                Text("Clicking the icon shows or hides the calculator at its last position.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            GroupBox(label: Text("Launch").font(.headline)) {
                HStack {
                    LaunchAtLogin.Toggle()
                    Spacer()
                }
                .padding(.vertical, 6)

                Text("Start the app automatically when you log in.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 460)
    }
}
