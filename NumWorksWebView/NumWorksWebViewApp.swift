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
    
    @Published var menuIconEnabled: Bool = false
    @Published var openInCurrentDesktop: Bool = true

    override init() {
        super.init()
        // Register first-run defaults for all settings
        UserDefaults.standard.register(defaults: [
            "MenuIconEnabled": true,            // show menu bar icon by default
            "OpenInCurrentDesktop": true,       // open in current desktop by default
            "HasInitializedShortcut": false     // no global shortcut recorded by default
        ])
        // Ensure published properties reflect the (now-registered) defaults
        self.menuIconEnabled = UserDefaults.standard.bool(forKey: "MenuIconEnabled")
        self.openInCurrentDesktop = UserDefaults.standard.bool(forKey: "OpenInCurrentDesktop")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure status item matches stored preference
        toggleMenuIcon(menuIconEnabled)
        
        // First-run only: set a default shortcut (⌥N)
        let hasInitShortcut = UserDefaults.standard.bool(forKey: "HasInitializedShortcut")
        if !hasInitShortcut {
            KeyboardShortcuts.setShortcut(.init(.n, modifiers: [.option]), for: .toggleWindow)
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
        
        
        // Check GitHub Releases for a newer version (silent if up-to-date or offline)
        UpdateChecker.shared.checkOnLaunch()
        
        DispatchQueue.main.async { [weak self] in
            self?.applySpaceBehavior()
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
    
    private func mainContentWindow() -> NSWindow? {
        // Prefer the window we tagged in WindowConfigurator
        if let w = NSApp.windows.first(where: { $0.frameAutosaveName == "MainWindow" }) {
            return w
        }
        // Fallback to the first titled window
        return NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) ?? NSApp.windows.first
    }
    
    private func applySpaceBehavior() {
        guard let win = mainContentWindow() else { return }
        var behavior = win.collectionBehavior
        if openInCurrentDesktop {
            behavior.insert(.moveToActiveSpace)
            behavior.remove(.canJoinAllSpaces)
        } else {
            behavior.remove(.moveToActiveSpace)
        }
        win.collectionBehavior = behavior
    }
    
    func setOpenInCurrentDesktop(_ newValue: Bool) {
        openInCurrentDesktop = newValue
        UserDefaults.standard.set(newValue, forKey: "OpenInCurrentDesktop")
        applySpaceBehavior()
    }
    
    private func isOnAnyScreen(_ frame: NSRect) -> Bool {
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
    
    
    func showMainWindow() {
        if let win = mainContentWindow() {
            showOnActiveSpace(win)
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    func toggleMainWindow() {
        let isFrontmost = NSApp.isActive
        guard let win = mainContentWindow() else {
            // No window yet: just activate and let SwiftUI create it
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        if !isFrontmost {
            // App not frontmost: bring to front and show
            showOnActiveSpace(win)
            return
        }
        
        // App is frontmost
        if win.isVisible {
            // Window visible → hide it
            win.orderOut(nil)
        } else {
            // Window not visible → show it
            showOnActiveSpace(win)
        }
    }
    
    func setMenuIconEnabled(_ newValue: Bool) {
        menuIconEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: "MenuIconEnabled")
        toggleMenuIcon(newValue)
    }
    
    
    // Show the window on the active Space and ensure it's frontmost and visible
    private func showOnActiveSpace(_ win: NSWindow) {
        // Ensure the correct Space behavior is applied
        applySpaceBehavior()
        if openInCurrentDesktop { win.collectionBehavior.insert(.moveToActiveSpace) }
        
        // Normalize window level in case it was altered
        win.level = .normal
        
        // Activate, restore, and bring to front (macOS 14+ safe)
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: false)

        WindowFrameStore.restore(on: win)
        if win.isMiniaturized { win.deminiaturize(nil) }

        // Ensure the window is on the current Space and briefly float it to avoid sitting behind the current front app
        win.collectionBehavior.insert(.moveToActiveSpace)
        let originalLevel = win.level
        win.level = .floating
        win.makeKeyAndOrderFront(nil)

        // After potential Space animation completes, assert frontmost again and restore original level.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApplication.shared.unhide(nil)
            if !win.isKeyWindow || !win.isVisible {
                win.makeKeyAndOrderFront(nil)
            }
            win.level = originalLevel
        }
        
        // If the restored frame ended up off-screen, recenter and bring forward again.
        if !isOnAnyScreen(win.frame), let screen = NSScreen.main {
            let size = win.frame.size
            let origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            )
            win.setFrame(NSRect(origin: origin, size: size), display: false)
            win.orderFrontRegardless()
            win.makeKeyAndOrderFront(nil)
        }
    }

}
