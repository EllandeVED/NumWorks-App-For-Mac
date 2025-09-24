import AppKit

@MainActor final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    var onShowApp: (() -> Void)?

    func create() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "n.square", accessibilityDescription: "NumWorks") {
            img.isTemplate = true            // adopts menu bar color
            item.button?.image = img
        } else {
            item.button?.title = "N"
        }
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(statusButtonClicked(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseUp])
        statusItem = item
    }

    func destroy() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func showApp() { onShowApp?() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleFromStatusItem() {
        if let app = (NSApp.delegate as? AppDelegate) {
            app.toggleMainWindow()
            return
        }
        // Fallbacks: try the callback, then direct window toggle
        if let cb = onShowApp { cb(); return }
        if let win = NSApp.windows.first {
            if win.isVisible {
                win.orderOut(nil)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                win.makeKeyAndOrderFront(nil)
            }
        }
    }


    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { toggleFromStatusItem(); return }
        if event.type == .rightMouseUp {
            let settingsItem = NSMenuItem(
                title: "Settings…",
                action: #selector(openSettings),
                keyEquivalent: ","
            )
            settingsItem.keyEquivalentModifierMask = [.command]  // ⌘ + ,
            settingsItem.target = self

            let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
            quitItem.keyEquivalentModifierMask = [.command]
            quitItem.target = self

            let m = NSMenu()
            m.items = [settingsItem, .separator(), quitItem]
            let pt = NSEvent.mouseLocation
            m.popUp(positioning: nil, at: pt, in: nil)
        } else {
            toggleFromStatusItem()
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

enum WindowFrameStore {
    static let key = "MainWindowFrame"

    static func save(_ window: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }

    static func restore(on window: NSWindow) {
        guard let s = UserDefaults.standard.string(forKey: key) else { return }
        let frame = NSRectFromString(s)
        window.setFrame(frame, display: false)
    }
}
