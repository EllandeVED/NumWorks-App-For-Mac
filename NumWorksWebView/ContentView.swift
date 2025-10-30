import SwiftUI
import WebKit
import AppKit
import Network   // ← add this

extension Notification.Name {
    static let netStatusChanged = Notification.Name("netStatusChanged")
}

// Helper to configure the NSWindow (aspect, min size, title)
struct WindowConfigurator: NSViewRepresentable {
    private static let minContentSize = NSSize(width:200, height: 390)
    final class Coordinator: NSObject, NSWindowDelegate {
        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            let minContent = WindowConfigurator.minContentSize
            let minFrame = sender.frameRect(forContentRect: NSRect(origin: .zero, size: minContent)).size
            var s = frameSize
            if s.width < minFrame.width { s.width = minFrame.width }
            if s.height < minFrame.height { s.height = minFrame.height }
            return s
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let win = v.window {
                win.setFrameAutosaveName("MainWindow")
                WindowFrameStore.restore(on: win)

                NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification, object: win, queue: .main
                ) { _ in WindowFrameStore.save(win) }

                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: win, queue: .main
                ) { _ in WindowFrameStore.save(win) }

                let aspect = NSSize(width: Self.minContentSize.width, height: Self.minContentSize.height)
                win.title = "NumWorks"
                win.backgroundColor = .black
                win.styleMask.insert(.resizable)
                win.aspectRatio = aspect
                win.contentMinSize = Self.minContentSize
                win.minSize = win.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minContentSize)).size
                win.setContentSize(Self.minContentSize)
                win.delegate = context.coordinator
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// WebView that waits for internet and auto-loads when available
struct WebView: NSViewRepresentable {
    let urlString: String

    func makeCoordinator() -> Coordinator { Coordinator(urlString: urlString) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: cfg)
        view.pageZoom = 1.0
        view.setValue(false, forKey: "drawsBackground")

        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .duringViewResize

        view.navigationDelegate = context.coordinator

        // Observe explicit load/reload requests
        NotificationCenter.default.addObserver(
            forName: .loadCalculatorNow,
            object: nil,
            queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.loadIfNeeded()
        }

        NotificationCenter.default.addObserver(
            forName: .reloadCalculatorNow,
            object: nil,
            queue: .main
        ) { [weak view] _ in
            view?.reload()
        }

        context.coordinator.webView = view
        context.coordinator.startMonitoringAndLoadWhenOnline()

        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "net.path.monitor")
        private let urlString: String
        private var didLoadOnce = false

        init(urlString: String) {
            self.urlString = urlString
        }

        func startMonitoringAndLoadWhenOnline() {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let online = (path.status == .satisfied)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .netStatusChanged, object: online)
                    if online && !self.didLoadOnce {
                        self.loadIfNeeded()
                    }
                }
            }
            monitor.start(queue: queue)
        }

        func loadIfNeeded() {
            guard let wv = webView, let url = URL(string: urlString) else { return }
            if !didLoadOnce {
                didLoadOnce = true
                let req = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30)
                wv.load(req)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Announce first successful load and stop monitoring so we never reload again
            NotificationCenter.default.post(name: .calculatorDidLoad, object: nil)
            monitor.cancel()
            monitor.pathUpdateHandler = nil
        }
    }
}

struct ContentView: View {
    @State private var isOnline = true
    @State private var hasLoadedEver = false
    @State private var isHoveringPin = false
    @State private var wasInsidePin = false
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WindowConfigurator().frame(width: 0, height: 0)
            WebView(urlString: "https://www.numworks.com/simulator/embed/")
                .ignoresSafeArea()
                .opacity(appDelegate.showWaitingScreen ? 0 : 1)

            if appDelegate.showWaitingScreen {
                // WAITING OVERLAY (full-screen, perfectly centered)
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        Text(isOnline ? "Loading calculator…" : "Waiting for internet…")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        Text("The calculator will load automatically.\nIf it seems stuck, try reloading the calculator.")
                            .font(.system(size: 15))
                            .foregroundColor(Color.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        
                        if !isOnline {
                            Text("No internet detected")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        
                        Button {
                            NotificationCenter.default.post(name: .reloadCalculatorNow, object: nil)
                        } label: {
                            Text("Reload calculator")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    // Make the stack occupy the whole window and center its contents
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            if appDelegate.showPinIcon && (appDelegate.pinIconPlacement == .onApp || appDelegate.pinIconPlacement == .both) {
                HStack { // padding lives outside the hit box
                    let pinDiameter: CGFloat = 28
                    FirstMouseContainer {
                        ZStack {
                            PinStickIcon(active: appDelegate.keepAtFront)
                        }
                    }
                    .frame(width: pinDiameter, height: pinDiameter)
                    .background(.regularMaterial)
                    .clipShape(Circle())
                    .contentShape(Circle()) // precise round hitbox
                    .overlay(
                        Circle()
                            .fill(Color.gray.opacity(isHoveringPin ? 0.25 : 0))
                            .allowsHitTesting(false)
                    )
                    .onTapGesture {
                        // Only toggle if the pointer is (or was) inside the same circular area that produced haptics
                        if wasInsidePin || isHoveringPin {
                            appDelegate.toggleKeepAtFront()
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let r = pinDiameter / 2
                            let center = CGPoint(x: r, y: r)
                            let dx = location.x - center.x
                            let dy = location.y - center.y
                            let inside = (dx*dx + dy*dy) <= (r*r)
                            isHoveringPin = inside
                            if inside && !wasInsidePin {
                                #if canImport(AppKit)
                                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                                #endif
                            }
                            wasInsidePin = inside
                        case .ended:
                            isHoveringPin = false
                            wasInsidePin = false
                        }
                    }
                    .help(appDelegate.keepAtFront ? "Don’t keep at the front" : "Keep at the front")
                }
                .padding(8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .netStatusChanged)) { note in
            if let online = note.object as? Bool, !hasLoadedEver {
                isOnline = online
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .calculatorDidLoad)) { _ in
            hasLoadedEver = true
            isOnline = true   // lock UI in 'online' state to prevent overlay
        }
    }
}
// An animated pin that “sticks” into a surface when active (tilt + down motion + shadow)
private struct PinStickIcon: View {
    var active: Bool
    @State private var trigger = false

    private struct PinAnimState: VectorArithmetic {
        var rotation: CGFloat  // degrees
        var yOffset: CGFloat   // points
        var shadow: CGFloat    // radius
        static var zero: PinAnimState { .init(rotation: 0, yOffset: 0, shadow: 0) }
        static func - (lhs: PinAnimState, rhs: PinAnimState) -> PinAnimState {
            .init(rotation: lhs.rotation - rhs.rotation, yOffset: lhs.yOffset - rhs.yOffset, shadow: lhs.shadow - rhs.shadow)
        }
        static func + (lhs: PinAnimState, rhs: PinAnimState) -> PinAnimState {
            .init(rotation: lhs.rotation + rhs.rotation, yOffset: lhs.yOffset + rhs.yOffset, shadow: lhs.shadow + rhs.shadow)
        }
        mutating func scale(by rhs: Double) {
            rotation *= rhs; yOffset *= rhs; shadow *= rhs
        }
        var magnitudeSquared: Double { Double(rotation*rotation + yOffset*yOffset + shadow*shadow) }
    }

    var body: some View {
        ZStack {
            // subtle paper beneath, compresses slightly when active
            RoundedRectangle(cornerRadius: 4)
                .fill(.secondary.opacity(0.10))
                .frame(width: 20, height: 10)
                .scaleEffect(x: 1, y: active ? 0.88 : 1, anchor: .center)
                .animation(.spring(response: 0.22, dampingFraction: 0.88), value: active)
                .opacity(0.9)

            Image(systemName: active ? "pin.fill" : "pin")
                .imageScale(.medium)
                .keyframeAnimator(
                    initialValue: PinAnimState(
                        rotation: active ? 12 : 0,
                        yOffset: 0,
                        shadow: 1
                    ),
                    trigger: trigger
                ) { content, value in
                    content
                        .rotationEffect(.degrees(value.rotation))
                        .offset(y: value.yOffset)
                        .shadow(radius: value.shadow)
                } keyframes: { _ in
                    // Rotation track
                    KeyframeTrack(\.rotation) {
                        if active {
                            CubicKeyframe(18, duration: 0.08)
                            CubicKeyframe(6, duration: 0.10)
                            CubicKeyframe(10, duration: 0.10)
                            CubicKeyframe(12, duration: 0.12)
                        } else {
                            CubicKeyframe(6, duration: 0.10)
                            CubicKeyframe(2, duration: 0.10)
                            CubicKeyframe(0, duration: 0.12)
                        }
                    }
                    // Vertical offset track
                    KeyframeTrack(\.yOffset) {
                        if active {
                            CubicKeyframe(3, duration: 0.08)
                            CubicKeyframe(-2, duration: 0.10)
                            CubicKeyframe(1, duration: 0.10)
                            CubicKeyframe(0, duration: 0.12)
                        } else {
                            CubicKeyframe(-4, duration: 0.10)
                            CubicKeyframe(-2, duration: 0.10)
                            CubicKeyframe(0, duration: 0.12)
                        }
                    }
                    // Shadow track
                    KeyframeTrack(\.shadow) {
                        if active {
                            CubicKeyframe(5, duration: 0.08)
                            CubicKeyframe(3, duration: 0.20)
                            CubicKeyframe(2, duration: 0.12)
                        } else {
                            CubicKeyframe(3, duration: 0.10)
                            CubicKeyframe(2, duration: 0.10)
                            CubicKeyframe(1, duration: 0.12)
                        }
                    }
                }
        }
        .onChange(of: active) { _, _ in trigger.toggle() }
    }
}

// A tiny AppKit bridge so the control accepts the first click even if the window isn't key
private struct FirstMouseContainer<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> FirstMouseHosting<Content> {
        FirstMouseHosting(rootView: content)
    }

    func updateNSView(_ nsView: FirstMouseHosting<Content>, context: Context) {
        nsView.rootView = content
    }
}

private final class FirstMouseHosting<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
