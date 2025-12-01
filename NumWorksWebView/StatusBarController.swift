import AppKit

@MainActor final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var originalStatusImage: NSImage?

    private let iconScaleFactor: CGFloat = 0.90     // slightly larger icon, still leaves room for badges
    private let badgeSizeFactor: CGFloat = 0.40      // refined badge size for nicer proportions
    private let badgePadding: CGFloat = 1.0          // subtle inset from edges
    private let badgeStrokeFactor: CGFloat = 0.06    // thinner outline for elegance

    private var baseIcon: NSImage?
    // Separate flags for the “pin” badge (Keep at front) and the update badge
    private var showPinBadge: Bool = false
    private var showUpdateBadge: Bool = false
    private var isLoadingOverlay: Bool = false
    
    private var currentIcon: NSImage?

    var onShowApp: (() -> Void)?
    weak var appDelegate: AppDelegate?

    func create() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            baseIcon = img
            originalStatusImage = img
            self.currentIcon = img  // Store strong reference
            item.button?.image = self.currentIcon  // Use stored reference
            item.length = NSStatusItem.squareLength // avoid clipping the badge
            updateIcon()                      // apply current badge state
        } else {
            item.button?.title = "N"
            item.length = NSStatusItem.squareLength
            baseIcon = item.button?.image
            updateIcon()
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
            originalStatusImage = nil
        }
    }

    // MARK: - Dynamic badge API (pin badge for “Keep at front”)
    func showBadge() { showPinBadge = true; updateIcon() }
    func removeBadge() { showPinBadge = false; updateIcon() }
    func toggleBadge() { showPinBadge.toggle(); updateIcon() }

    // Explicit API for the update badge (bell)
    func setUpdateBadgeVisible(_ visible: Bool) {
        showUpdateBadge = visible
        updateIcon()
    }

    func setLoadingOverlay(_ show: Bool) {
        isLoadingOverlay = show
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        guard let base = baseIcon ?? button.image else { return }

        let iconSize = base.size
        let scaledSize = NSSize(width: iconSize.width * iconScaleFactor,
                                height: iconSize.height * iconScaleFactor)
        let offset = NSPoint(x: (iconSize.width - scaledSize.width) / 2,
                             y: (iconSize.height - scaledSize.height) / 2)

        let composed = NSImage(size: iconSize)
        composed.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: iconSize)).fill()

        // Base icon (centered + scaled)
        base.draw(in: NSRect(origin: offset, size: scaledSize),
                  from: .zero,
                  operation: .sourceOver,
                  fraction: 1.0)

        // Pin badge (bottom-right) if requested
        if showPinBadge {
            drawPinBadge(in: iconSize)
        }

        // Update badge (top-right) if requested
        if showUpdateBadge {
            drawUpdateBadge(in: iconSize)
        }

        // Optional loading overlay bar at the bottom
        if isLoadingOverlay {
            let size = iconSize
            let barHeight = max(2, size.height * 0.12)
            let barWidth  = size.width * 0.72
            let barX = (size.width - barWidth) / 2
            let barY = size.height * 0.10
            let barRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: barHeight/2, yRadius: barHeight/2)
            NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
            path.fill()
        }

        composed.unlockFocus()

        // If we’re drawing colored overlays (badges or loading bar), don’t use template rendering.
        let hasColorOverlay = showPinBadge || showUpdateBadge || isLoadingOverlay
        composed.isTemplate = !hasColorOverlay
        self.currentIcon = composed
        button.image = self.currentIcon
        button.image?.isTemplate = !hasColorOverlay
        button.needsDisplay = true
    }

    // Bottom-right pin badge (used for “keep at front”)
    private func drawPinBadge(in iconSize: NSSize) {
        let pinColor: NSColor = NSColor(hex: "#000000") ?? .black

        // CIRCLE SIZE
        let circleDiameter = max(8, iconSize.height * (badgeSizeFactor + 0.08))

        // Helper to snap to 0.5pt for sharper rendering on Retina
        func snap(_ v: CGFloat) -> CGFloat { round(v * 2) / 2 }

        if let sym = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) {
            let circleRadius = circleDiameter / 2
            let cx = snap(iconSize.width - circleRadius - badgePadding)
            let cy = snap(badgePadding + circleRadius)
            let circleRect = NSRect(x: cx - circleRadius, y: cy - circleRadius, width: circleDiameter, height: circleDiameter)

            let circleFill = NSColor(hex: "#C0C0C0") ?? NSColor(calibratedRed: 0.75, green: 0.75, blue: 0.75, alpha: 1.0)
            let circlePath = NSBezierPath(ovalIn: circleRect)
            circleFill.setFill()
            circlePath.fill()

            let inset = circleDiameter * 0.04
            let pinRect = circleRect.insetBy(dx: inset, dy: inset)
            let baseCfg = NSImage.SymbolConfiguration(pointSize: pinRect.height, weight: .regular)
            let colorCfg = NSImage.SymbolConfiguration(hierarchicalColor: pinColor)
            let cfg = baseCfg.applying(colorCfg)
            let pinImg = sym.withSymbolConfiguration(cfg) ?? sym
            pinImg.isTemplate = false

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: pinRect.midX, yBy: pinRect.midY)
            transform.rotate(byDegrees: -18)
            transform.translateX(by: -pinRect.midX, yBy: -pinRect.midY)
            transform.concat()

            let shadow = NSShadow()
            shadow.shadowBlurRadius = circleDiameter * 0.08
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()

            pinImg.draw(in: pinRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let d = circleDiameter * 0.5
            let r = NSRect(x: iconSize.width - d - badgePadding, y: badgePadding, width: d, height: d)
            NSColor(calibratedWhite: 0.2, alpha: 1.0).setFill()
            NSBezierPath(ovalIn: r).fill()
        }
    }

    // Top-right bell badge for “update available”
    private func drawUpdateBadge(in iconSize: NSSize) {
        // LARGE update badge — independent from pin size, roughly 2× bigger
        let circleDiameter = max(12, iconSize.height * 0.25)
        let circleRadius = circleDiameter / 2

        // Helper to snap to 0.5pt for sharper rendering on Retina
        func snap(_ v: CGFloat) -> CGFloat { round(v * 2) / 2 }

        // Position of the badge
        let cx = snap(iconSize.width - circleRadius - badgePadding + circleRadius * 0.55) //X
        let cy = snap(iconSize.height - circleRadius - badgePadding + circleRadius * 0.60) //Y
        let badgeRect = NSRect(x: cx - circleRadius, y: cy - circleRadius, width: circleDiameter, height: circleDiameter)

        // Draw a red bell.badge.fill symbol centered in this rect
        if let bellBadge = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil) {
            let inset = circleDiameter * 0.05   // much larger bell icon
            let symbolRect = badgeRect.insetBy(dx: inset, dy: inset)

            let baseCfg = NSImage.SymbolConfiguration(pointSize: symbolRect.height, weight: .regular)
            // Use a single palette color to force a solid, monochrome red appearance
            let red = NSColor(red: 1, green: 0, blue: 0, alpha: 1)
            let colorCfg = NSImage.SymbolConfiguration(paletteColors: [red])
            let cfg = baseCfg.applying(colorCfg)

            let bellImg = bellBadge.withSymbolConfiguration(cfg) ?? bellBadge
            bellImg.isTemplate = false
            bellImg.draw(in: symbolRect,
                         from: NSRect.zero,
                         operation: .sourceOver,
                         fraction: 1.0)
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
            settingsItem.keyEquivalentModifierMask = NSEvent.ModifierFlags.command  // ⌘ + ,
            settingsItem.target = self

            let keepTitle = (appDelegate?.keepAtFront == true)
                ? "Unkeep in front of all windows"
                : "Keep in front of all windows"
            let keepItem = NSMenuItem(
                title: keepTitle,
                action: #selector(toggleKeepAtFrontFromMenu),
                keyEquivalent: ""
            )
            keepItem.target = self

            let reloadItem = NSMenuItem(
                title: "Reload",
                action: #selector(reloadCalculator),
                keyEquivalent: "r"
            )
            reloadItem.keyEquivalentModifierMask = NSEvent.ModifierFlags.command
            reloadItem.target = self

            let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
            quitItem.keyEquivalentModifierMask = NSEvent.ModifierFlags.command
            quitItem.target = self

            let m = NSMenu()
            m.items = [settingsItem, keepItem, reloadItem, .separator(), quitItem]
            if let btn = statusItem?.button {
                m.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height), in: btn)
            }
        } else {
            toggleFromStatusItem()
        }
    }

    @objc private func toggleFromStatusItem() {
        if let app = (NSApp.delegate as? AppDelegate) {
            if app.hasLoadedEver {
                app.toggleMainWindow()
            } else {
                DispatchQueue.main.async { app.showMainWindow() }
            }
            return
        }
        onShowApp?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
    }

    @objc private func toggleKeepAtFrontFromMenu() {
        appDelegate?.toggleKeepAtFront()
    }

    @objc private func reloadCalculator(_ sender: Any? = nil) {
        NotificationCenter.default.post(name: .reloadCalculatorNow, object: nil)
    }
    // Adds or removes a small pin badge on the menubar icon
    func updatePinOverlay(show: Bool) {
        if show { showBadge() } else { removeBadge() }
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexSanitized.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
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
