import AppKit

final class StatusBarController: NSObject {
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

        let showItem = NSMenuItem(title: "Show NumWorks", action: #selector(showApp), keyEquivalent: "")
        showItem.target = self
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.items = [showItem, .separator(), quitItem]
        item.menu = menu
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
