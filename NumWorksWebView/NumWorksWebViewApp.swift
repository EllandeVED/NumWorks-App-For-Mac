import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin
import AppKit
import Combine
import Network

extension Notification.Name {
    static let networkBecameReachable = Notification.Name("NetworkBecameReachable")
    static let loadCalculatorNow = Notification.Name("LoadCalculatorNow")
    static let calculatorDidLoad = Notification.Name("CalculatorDidLoad")
    static let reloadCalculatorNow = Notification.Name("ReloadCalculatorNow")
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

    var commands: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                (NSApp.delegate as? AppDelegate)?.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let status = StatusBarController()

    // +++ Simple online state you can also bind to UI if you want a “waiting” screen
    @Published var isOnline: Bool = true

    // Track whether the calculator has ever loaded successfully (to avoid later auto-reloads)
    @Published var hasLoadedEver: Bool = false

    // +++ Network monitor
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "NetPathMonitor")
    private var wasOnline: Bool = false
    // When true, all connectivity monitoring is permanently disabled for this run
    private var connectivityChecksDisabled: Bool = false

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

        // Mark once the calculator has successfully loaded (prevents future auto-reloads / waiting screen)
        NotificationCenter.default.addObserver(forName: .calculatorDidLoad, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.disableConnectivityChecks()
            }
        }

        // +++ Start monitoring connectivity
        startNetworkMonitoring()

        // Capture ⌘, locally even when the menu is not first
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only when exactly Command + Comma is pressed (no other modifiers)
            let wantsCommand = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if wantsCommand, event.characters == "," {
                self?.openSettings()
                return nil  // consume the event so it doesn't bubble
            }
            return event
        }
    }

    // Permanently disable all connectivity monitoring & UI flips after first successful load
    private func disableConnectivityChecks() {
        guard !connectivityChecksDisabled else { return }
        hasLoadedEver = true
        isOnline = true
        connectivityChecksDisabled = true
        // Stop and detach the NWPathMonitor to prevent further callbacks
        pathMonitor.cancel()
        pathMonitor.pathUpdateHandler = nil
    }

    private func startNetworkMonitoring() {
        // Do not start monitoring if we already loaded once or if disabled
        if connectivityChecksDisabled || hasLoadedEver { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let nowOnline = (path.status == .satisfied)
            DispatchQueue.main.async {
                // If checks are disabled or we've already loaded, ignore further updates
                if self.connectivityChecksDisabled || self.hasLoadedEver { return }
                // After the first successful load, do NOT toggle the UI back to "waiting"
                if !self.hasLoadedEver {
                    self.isOnline = nowOnline
                }

                // Only request initial load on the first offline→online transition;
                // never auto-trigger loads after the calculator has loaded once.
                if nowOnline && !self.wasOnline && !self.hasLoadedEver {
                    NotificationCenter.default.post(name: .loadCalculatorNow, object: nil)
                }
                self.wasOnline = nowOnline
            }
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

    @objc func openSettings() {
        // Opens the SwiftUI Settings scene window and brings app to front
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
}
