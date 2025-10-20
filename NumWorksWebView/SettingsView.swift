import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        ScrollView { // prevents clipping on small windows
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Shortcut
                GroupBox("Shortcut") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Choose your shortcut to Show/Hide the calculator")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleWindow)
                            .fixedSize()
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)

                // MARK: Menu Bar
                GroupBox("Menu Bar") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(
                            "Show menu bar icon",
                            isOn: Binding(
                                get: { appDelegate.menuIconEnabled },
                                set: { appDelegate.setMenuIconEnabled($0) }
                            )
                        )
                        Text("Clicking the icon shows or hides the calculator at its last position.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)

                // MARK: Launch
                GroupBox("Launch") {
                    VStack(alignment: .leading, spacing: 6) {
                        LaunchAtLogin.Toggle()
                        Text("Start the app automatically when you log in.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)



                GroupBox("Desktop") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(
                            "Open in current desktop",
                            isOn: Binding(
                                get: { appDelegate.openInCurrentDesktop },
                                set: { appDelegate.setOpenInCurrentDesktop($0) }
                            )
                        )
                        Text("If off, the window stays on the desktop where you left it.")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                
                // MARK: About
                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 8) {
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

                        VStack(alignment: .leading, spacing: 2) {
                            Text("NumWorks for Mac")
                            Text("Version \(version)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }

                        HStack {
                            Link("See on GitHub (Support)", destination: URL(string: "https://github.com/EllandeVED/NumWorks-App-For-Mac")!)
                            Spacer()
                            Button("Check for Updates…") {
                                UpdateChecker.shared.checkNow()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 48)   // ← consistent side margins
            .padding(.vertical, 16)     // ← top/bottom margins
        }
        .frame(minWidth: 520, minHeight: 460)
    }
}
