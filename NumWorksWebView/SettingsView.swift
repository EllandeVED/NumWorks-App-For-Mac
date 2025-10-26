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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Choose your shortcut to Show/Hide the calculator")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .toggleWindow)
                                .fixedSize()
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Keep in front of all windows")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .toggleKeepAtFront)
                                .fixedSize()
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)

                // MARK: Pin Icon
                GroupBox("Pin icon") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Show pin icon",
                            isOn: Binding(
                                get: { appDelegate.showPinIcon },
                                set: { appDelegate.setShowPinIcon($0) }
                            )
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Show where:")
                                .font(.callout)
                                .foregroundColor(.primary)

                            SlidingSegmentedControl(
                                selection: Binding(
                                    get: { appDelegate.pinIconPlacement },
                                    set: { appDelegate.setPinIconPlacement($0) }
                                ),
                                segments: [
                                    ("On app", .onApp),
                                    ("On menu bar icon", .onMenu),
                                    ("Both", .both)
                                ]
                            )
                            .frame(maxWidth: .infinity) // expand to match other group boxes
                            .opacity(appDelegate.showPinIcon ? 1.0 : 0.5)
                            .disabled(!appDelegate.showPinIcon)
                        }
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

private struct SlidingSegmentedControl: View {
    @Binding var selection: AppDelegate.PinIconPlacement
    let segments: [(String, AppDelegate.PinIconPlacement)]
    @Namespace private var thumbNS

    var body: some View {
        GeometryReader { geo in
            let count = max(1, segments.count)
            let w = (geo.size.width / CGFloat(count)).rounded(.down)

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    )

                // Thumb (blue, slides between options)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .systemBlue))
                    .frame(width: w - 6, height: max(28, geo.size.height - 8))
                    .offset(x: xOffset(width: w) + 3)
                    .matchedGeometryEffect(id: "thumb", in: thumbNS)
                    .animation(.easeInOut(duration: 0.20), value: selection)

                // Labels row
                HStack(spacing: 0) {
                    ForEach(segments.indices, id: \.self) { idx in
                        let item = segments[idx]
                        Button(action: { selection = item.1 }) {
                            Text(item.0)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85) // shrink slightly to fit longer labels
                                .frame(width: w, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == item.1 ? Color.white : Color.primary)
                    }
                }
            }
        }
        .frame(height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func xOffset(width w: CGFloat) -> CGFloat {
        guard let idx = segments.firstIndex(where: { $0.1 == selection }) else { return 0 }
        return CGFloat(idx) * w
    }
}
