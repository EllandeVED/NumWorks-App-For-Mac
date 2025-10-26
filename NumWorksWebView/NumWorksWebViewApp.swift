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
            ContentView().environmentObject(appDelegate)
        }
        
        Settings {
            SettingsView(appDelegate: appDelegate)
                .frame(width: 460)
        }
    }
}

extension KeyboardShortcuts.Name {
    /// Global shortcut to toggle the "Keep in front of all windows" feature.
    static let toggleKeepAtFront = Self("toggleKeepAtFront")
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private let status = StatusBarController()
    
    // +++ Simple online state you can also bind to UI if you want a “waiting” screen
    @Published var isOnline: Bool = true
    
    // Track whether the calculator has ever loaded successfully (to avoid later auto-reloads)
    @Published var hasLoadedEver: Bool = false

    // Show a loading indicator when online but calculator hasn't loaded yet
    @Published var isLoadingSlow: Bool = false
    private var slowLoadWork: DispatchWorkItem?
    private let slowLoadDelay: TimeInterval = 2.0
    
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
                self?.cancelSlowLoadDetection()
                self?.disableConnectivityChecks()
            }
        }
        
        // +++ Start monitoring connectivity
        startNetworkMonitoring()

        // If we haven't loaded yet, arm slow-load indicator right away (will auto-cancel on load)
        if !hasLoadedEver && !connectivityChecksDisabled {
            startSlowLoadDetectionIfNeeded()
        }

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
        status.setLoadingOverlay(false)
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
                    self.startSlowLoadDetectionIfNeeded()
                }
                self.wasOnline = nowOnline
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func startSlowLoadDetectionIfNeeded() {
        // Only show when we are online, haven't loaded yet, and not already showing
        if connectivityChecksDisabled || hasLoadedEver || isLoadingSlow { return }
        cancelSlowLoadDetection()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if !self.hasLoadedEver && !self.connectivityChecksDisabled {
                self.isLoadingSlow = true
                self.status.setLoadingOverlay(true)
            }
        }
        slowLoadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + slowLoadDelay, execute: work)
    }

    private func cancelSlowLoadDetection() {
        slowLoadWork?.cancel()
        slowLoadWork = nil
        if isLoadingSlow {
            isLoadingSlow = false
            status.setLoadingOverlay(false)
        }
    }
    
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
            if !hasLoadedEver && !connectivityChecksDisabled {
                startSlowLoadDetectionIfNeeded()
            }
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
            if !hasLoadedEver && !connectivityChecksDisabled { startSlowLoadDetectionIfNeeded() }
            showOnActiveSpace(win)
            return
        }
        
        // App is frontmost
        if win.isVisible {
            // Window visible → hide it
            win.orderOut(nil)
        } else {
            // Window not visible → show it
            if !hasLoadedEver && !connectivityChecksDisabled { startSlowLoadDetectionIfNeeded() }
            showOnActiveSpace(win)
        }
    }
    
    func setMenuIconEnabled(_ newValue: Bool) {
        menuIconEnabled = newValue
        UserDefaults.standard.set(newValue, forKey: "MenuIconEnabled")
        toggleMenuIcon(newValue)
        if newValue, !hasLoadedEver && !connectivityChecksDisabled {
            startSlowLoadDetectionIfNeeded()
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
    
}
