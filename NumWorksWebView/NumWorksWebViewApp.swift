import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
import AppKit
import Combine
import Network   // +++

extension Notification.Name {
    static let networkBecameReachable = Notification.Name("NetworkBecameReachable")
}

@main
struct NumWorksWebViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        Settings {
            SettingsView(appDelegate: appDelegate)
                .frame(width: 460)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let status = StatusBarController()

    // +++ Simple online state you can also bind to UI if you want a “waiting” screen
    @Published var isOnline: Bool = true

    // +++ Network monitor
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "NetPathMonitor")

    @Published var menuIconEnabled: Bool =
        (UserDefaults.standard.object(forKey: "MenuIconEnabled") as? Bool) ?? false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure status item matches stored preference
        toggleMenuIcon(menuIconEnabled)

        // First-run only: ensure no default shortcut is recorded
        let hasInitShortcut = UserDefaults.standard.bool(forKey: "HasInitializedShortcut")
        if !hasInitShortcut {
            KeyboardShortcuts.reset(.toggleWindow)
            UserDefaults.standard.set(true, forKey: "HasInitializedShortcut")
        }

        // Register handler for global shortcut if user sets one
        KeyboardShortcuts.onKeyUp(for: .toggleWindow) { [weak self] in
            self?.toggleMainWindow()
        }

        // +++ Start monitoring connectivity
        startNetworkMonitoring()
    }

    private func startNetworkMonitoring() {
        var lastOnline = false
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let nowOnline = (path.status == .satisfied)
            DispatchQueue.main.async {
                self?.isOnline = nowOnline

                // Fire only on transition from offline -> online
                if nowOnline && !lastOnline {
                    NotificationCenter.default.post(name: .networkBecameReachable, object: nil)
                }
            }
            lastOnline = nowOnline
        }
        pathMonitor.start(queue: pathQueue)
    }

    func toggleMenuIcon(_ enabled: Bool) {
        if enabled {
            status.onShowApp = { [weak self] in self?.toggleMainWindow() }
            status.create()
        } else {
            status.destroy()
        }
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first {
            WindowFrameStore.restore(on: win)
            win.makeKeyAndOrderFront(nil)
        }
    }

    func toggleMainWindow() {
        if let win = NSApp.windows.first {
            if win.isVisible {
                win.orderOut(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                WindowFrameStore.restore(on: win)
                win.makeKeyAndOrderFront(nil)
            }
        }
    }

    func setMenuIconEnabled(_ newValue: Bool) {
        menuIconEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: "MenuIconEnabled")
        toggleMenuIcon(newValue)
    }
}
