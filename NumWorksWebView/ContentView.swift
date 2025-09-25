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

    var body: some View {
        ZStack {
            WindowConfigurator().frame(width: 0, height: 0)
            WebView(urlString: "https://www.numworks.com/simulator/embed/")
                .ignoresSafeArea()
                .opacity(isOnline ? 1 : 0)

            if !hasLoadedEver && !isOnline {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for internet…").font(.headline)
                    Text("The calculator will load automatically.").font(.subheadline).opacity(0.7)
                }
                .padding()
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
