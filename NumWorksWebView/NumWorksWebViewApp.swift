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
    static let openSettingsRequest = Notification.Name("OpenSettingsRequest")
}

private struct SettingsOpenerView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequest)) { _ in
                openWindow(id: "settings")
            }
    }
}

@main
struct NumWorksWebViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Main calculator window
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate)
                .background(SettingsOpenerView())
        }
        .commands {
            // Wire the standard Settings / Preferences menu item
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: "settings")
                }
                .keyboardShortcut(",", modifiers: [.command])   // normal macOS one
                .keyboardShortcut(";", modifiers: [.command])   // extra, just for testing
            }
            // Add Move to Applications… command after Settings
            CommandGroup(after: .appSettings) {
                Button("Move to Applications…") {
                    appDelegate.moveToApplicationsIfNeeded(userInitiated: true)
                }
                .disabled(appDelegate.isInApplicationsFolder)
            }
        }

        // Dedicated Settings window
        Window("Settings", id: "settings") {
            SettingsView(appDelegate: appDelegate)
                .frame(minWidth: 520, minHeight: 460)
        }
    }
}
extension KeyboardShortcuts.Name {
    //Global shortcut to toggle the "Keep in front of all windows" feature.
    static let toggleKeepAtFront = Self("toggleKeepAtFront")
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // Returns true if the app bundle is in /Applications or ~/Applications
    var isInApplicationsFolder: Bool {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path
        // Consider both system and user Applications folders
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private let status = StatusBarController()

    
    // +++ Simple online state you can also bind to UI if you want a “waiting” screen
    @Published var isOnline: Bool = true
    
    // Track whether the calculator has ever loaded successfully (to avoid later auto-reloads)
    @Published var hasLoadedEver: Bool = false

    // While true, ContentView should display a full-bleed waiting screen.
    // If `isOnline` is false during this time, show a small "No internet detected" notice on that screen.
    // When `.calculatorDidLoad` fires, this flag flips to false and connectivity checks are stopped.
    @Published var showWaitingScreen: Bool = true
    
    // Track whether we're currently attempting to load the calculator (prevents spam reloads)
    @Published var isAttemptingInitialLoad: Bool = false

    // +++ Network monitor
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "NetPathMonitor")
    private var wasOnline: Bool = false
    // When true, all connectivity monitoring is permanently disabled for this run
    private var connectivityChecksDisabled: Bool = false
    
    @Published var menuIconEnabled: Bool = false
    @Published var openInCurrentDesktop: Bool = true
    @Published var keepAtFront: Bool = UserDefaults.standard.bool(forKey: "KeepAtFront")
    enum PinIconPlacement: String, CaseIterable, Identifiable { case onApp, onMenu, both; var id: String { rawValue } }
    @Published var showPinIcon: Bool = UserDefaults.standard.bool(forKey: "ShowPinIcon")
    @Published var pinIconPlacement: PinIconPlacement = PinIconPlacement(rawValue: UserDefaults.standard.string(forKey: "PinIconPlacement") ?? "both") ?? .both

    override init() {
        super.init()
        // Register first-run defaults for all settings
        UserDefaults.standard.register(defaults: [
            "MenuIconEnabled": true,            // show menu bar icon by default
            "OpenInCurrentDesktop": true,       // open in current desktop by default
            "HasInitializedShortcut": false,    // no global shortcut recorded by default
            "KeepAtFront": false,
            "ShowPinIcon": true,   // Pin icon enabled by default
            "PinIconPlacement": "onApp", // Default placement: on the app window only
        ])
        // Ensure published properties reflect the (now-registered) defaults
        self.menuIconEnabled = UserDefaults.standard.bool(forKey: "MenuIconEnabled")
        self.openInCurrentDesktop = UserDefaults.standard.bool(forKey: "OpenInCurrentDesktop")
        self.keepAtFront = UserDefaults.standard.bool(forKey: "KeepAtFront")
        self.showPinIcon = UserDefaults.standard.bool(forKey: "ShowPinIcon")
        self.pinIconPlacement = PinIconPlacement(rawValue: UserDefaults.standard.string(forKey: "PinIconPlacement") ?? "both") ?? .both
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure status item matches stored preference
        toggleMenuIcon(menuIconEnabled)
        status.updatePinOverlay(show: showPinIcon && (pinIconPlacement == .onMenu || pinIconPlacement == .both) && keepAtFront)
        
        // First-run only: set a default shortcut (⌥N)
        let hasInitShortcut = UserDefaults.standard.bool(forKey: "HasInitializedShortcut")
        if !hasInitShortcut {
            // Default shortcut only for toggling the calculator window (⌥N)
            KeyboardShortcuts.setShortcut(.init(.n, modifiers: [.option]), for: .toggleWindow)
            // No default shortcut for Keep-At-Front (user must assign manually in Settings)
            UserDefaults.standard.set(true, forKey: "HasInitializedShortcut")
        }
        
        // Register handler for global shortcut if user sets one
        KeyboardShortcuts.onKeyUp(for: .toggleWindow) { [weak self] in
            self?.toggleMainWindow()
        }
        KeyboardShortcuts.onKeyUp(for: .toggleKeepAtFront) { [weak self] in
            self?.toggleKeepAtFront()
        }
        
        // Mark once the calculator has successfully loaded (prevents future auto-reloads / waiting screen)
        NotificationCenter.default.addObserver(forName: .calculatorDidLoad, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Hide waiting screen and permanently stop connectivity checks
                self.showWaitingScreen = false
                self.status.setLoadingOverlay(false)
                self.isAttemptingInitialLoad = false
                self.disableConnectivityChecks()
                // Defer update check until after the calculator has loaded to avoid blocking the load with a modal alert
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    UpdateChecker.shared.checkOnLaunch()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.maybePromptMoveToApplications()
                }
            }
        }

        NotificationCenter.default.addObserver(forName: .reloadCalculatorNow, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Re-enable monitoring for this reload cycle
                self.connectivityChecksDisabled = false
                self.hasLoadedEver = false
                self.showWaitingScreen = true
                self.status.setLoadingOverlay(true)
                self.isAttemptingInitialLoad = false

                // Restart monitoring and trigger a load if currently online
                self.startNetworkMonitoring()
                if self.isOnline {
                    NotificationCenter.default.post(name: .loadCalculatorNow, object: nil)
                }
            }
        }
        
        // +++ Start monitoring connectivity
        startNetworkMonitoring()
        showWaitingScreen = true
        status.setLoadingOverlay(true)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applySpaceBehavior()
        }
    }
    
    // Permanently disable all connectivity monitoring & UI flips after first successful load
    private func disableConnectivityChecks() {
        guard !connectivityChecksDisabled else { return }
        hasLoadedEver = true
        connectivityChecksDisabled = true
        // Stop and detach the NWPathMonitor to prevent further callbacks
        pathMonitor.cancel()
        pathMonitor.pathUpdateHandler = nil
        // Once loaded, we consider the runtime "online enough" and hide any overlays
        isOnline = true
        status.setLoadingOverlay(false)
    }
    
    private func startNetworkMonitoring() {
        // Do not start monitoring if permanently disabled for this run (after full load)
        if connectivityChecksDisabled { return }

        // Reset handler each time we (re)start
        pathMonitor.cancel()
        pathMonitor.pathUpdateHandler = nil

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let nowOnline = (path.status == .satisfied)
            DispatchQueue.main.async {
                if self.connectivityChecksDisabled { return } // once fully loaded, stop reacting

                // Update UI flag for the waiting screen notice
                self.isOnline = nowOnline

                // If we lost internet mid-load, allow a new attempt when it comes back
                if !nowOnline {
                    self.isAttemptingInitialLoad = false
                    self.wasOnline = false
                    return
                }

                // If we are still in waiting mode (calculator not visible yet), trigger a load when online.
                // Guard with isAttemptingInitialLoad so we don't spam multiple loads while already trying.
                if self.showWaitingScreen && nowOnline && !self.isAttemptingInitialLoad {
                    self.isAttemptingInitialLoad = true
                    NotificationCenter.default.post(name: .loadCalculatorNow, object: nil)
                }

                self.wasOnline = nowOnline
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    // (Removed: startSlowLoadDetectionIfNeeded and cancelSlowLoadDetection)
    
    func toggleMenuIcon(_ enabled: Bool) {
        if enabled {
            status.onShowApp = { [weak self] in self?.toggleMainWindow() }
            status.appDelegate = self
            status.create()
            status.updatePinOverlay(show: showPinIcon && (pinIconPlacement == .onMenu || pinIconPlacement == .both) && keepAtFront)
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
        // Immediately reflect behavior on the existing window
        if let win = mainContentWindow() {
            if newValue {
                // Ensure the flag is present and hop the window to the active Space now if visible
                win.collectionBehavior.insert(.moveToActiveSpace)
                if win.isVisible {
                    // Briefly bring to front to trigger the Space move, then restore focus if needed
                    let wasKey = win.isKeyWindow
                    NSApplication.shared.activate(ignoringOtherApps: false)
                    win.makeKeyAndOrderFront(nil)
                    // If it wasn't key before, avoid stealing focus: send it back
                    if !wasKey {
                        DispatchQueue.main.async {
                            NSApp.hide(nil)
                            NSApp.unhide(nil)
                        }
                    }
                }
            } else {
                // Removing the behavior is immediate; no hop needed
                win.collectionBehavior.remove(.moveToActiveSpace)
            }
        }
    }
    
    func setKeepAtFront(_ newValue: Bool) {
        keepAtFront = newValue
        UserDefaults.standard.set(newValue, forKey: "KeepAtFront")
        if let win = mainContentWindow() {
            applyKeepAtFrontBehavior(on: win)
        }
        status.updatePinOverlay(show: showPinIcon && (pinIconPlacement == .onMenu || pinIconPlacement == .both) && keepAtFront)
    }
    
    func toggleKeepAtFront() {
        setKeepAtFront(!keepAtFront)
    }
    
    private func applyKeepAtFrontBehavior(on win: NSWindow) {
        // Make the window float above normal apps when enabled; otherwise back to normal.
        win.level = keepAtFront ? .floating : .normal
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
        if newValue, showWaitingScreen {
            status.setLoadingOverlay(true)
        }
    }
    
    func setShowPinIcon(_ newValue: Bool) {
        showPinIcon = newValue
        UserDefaults.standard.set(newValue, forKey: "ShowPinIcon")
        status.updatePinOverlay(show: newValue && (pinIconPlacement == .onMenu || pinIconPlacement == .both) && keepAtFront)
    }
    
    func setPinIconPlacement(_ placement: PinIconPlacement) {
        pinIconPlacement = placement
        UserDefaults.standard.set(placement.rawValue, forKey: "PinIconPlacement")
        status.updatePinOverlay(show: showPinIcon && (placement == .onMenu || placement == .both) && keepAtFront)
    }
    
    // Show the window on the active Space and ensure it's frontmost and visible
    private func showOnActiveSpace(_ win: NSWindow) {
        // Ensure the correct Space behavior is applied (handled inside applySpaceBehavior)
        applySpaceBehavior()
        
        // Apply Keep-At-Front choice
        applyKeepAtFrontBehavior(on: win)
        
        // Activate, restore, and bring to front (macOS 14+ safe)
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: false)
        
        WindowFrameStore.restore(on: win)
        if win.isMiniaturized { win.deminiaturize(nil) }
        
        // Briefly ensure frontmost without clobbering persistent level
        let targetLevel = win.level
        if targetLevel == .normal {
            // Only bump if not already floating
            win.level = .floating
        }
        win.makeKeyAndOrderFront(nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApplication.shared.unhide(nil)
            if !win.isKeyWindow || !win.isVisible {
                win.makeKeyAndOrderFront(nil)
            }
            // Restore the intended level (normal or floating depending on setting)
            win.level = targetLevel
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
    
    // (Settings window management is now handled by SwiftUI Windows.)

    // Moves the app bundle to /Applications if not already there.
    func moveToApplicationsIfNeeded(userInitiated: Bool) {
        if isInApplicationsFolder {
            // Optionally show an alert here if userInitiated, but for simplicity just return.
            return
        }

        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let destinationDir = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let destinationURL = destinationDir.appendingPathComponent(bundleURL.lastPathComponent)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: bundleURL)
            } else {
                try fileManager.moveItem(at: bundleURL, to: destinationURL)
            }
            let opened = NSWorkspace.shared.open(destinationURL)
            if opened {
                NSApp.terminate(nil)
            }
        } catch {
            NSLog("Move to Applications failed: \(error.localizedDescription)")
        }
    }

    private func maybePromptMoveToApplications() {
        // Only prompt if not already in an Applications folder
        guard !isInApplicationsFolder else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "It's recommended to move NumWorksWebView to the Applications folder. This keeps it easy to find and helps future updates work correctly."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            moveToApplicationsIfNeeded(userInitiated: true)
        }
    }
}
