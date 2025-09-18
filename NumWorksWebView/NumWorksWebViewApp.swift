import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
import AppKit
import Combine

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
    
    @Published var menuIconEnabled: Bool =
        (UserDefaults.standard.object(forKey: "MenuIconEnabled") as? Bool) ?? false

    func applicationDidFinishLaunching(_ notification: Notification ) {
        // Ensure status item matches stored preference
        toggleMenuIcon(menuIconEnabled)

        // First-run only: ensure no default shortcut is recorded
        let hasInitShortcut = UserDefaults.standard.bool(forKey: "HasInitializedShortcut")
        if !hasInitShortcut {
            KeyboardShortcuts.reset(.toggleWindow) // clears any stored combo
            UserDefaults.standard.set(true, forKey: "HasInitializedShortcut")
        }

        // Register handler (no-op until user records a shortcut)
        KeyboardShortcuts.onKeyUp(for: .toggleWindow) { [weak self] in
            self?.toggleMainWindow()
        }

        // Register global shortcut once (app lifetime), decoupled from view lifecycle
        // KeyboardShortcuts.onKeyUp(for: .toggleWindow) { [weak self] in
        //     self?.toggleMainWindow()
        // }
    }

    func toggleMenuIcon(_ enabled: Bool) {
        if enabled {
            status.onShowApp = { [weak self] in self?.showMainWindow() }
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
        // Single place to update model + persist + apply UI
        menuIconEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: "MenuIconEnabled")
        toggleMenuIcon(newValue)
    }
}
