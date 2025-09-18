import SwiftUI
import WebKit

// Helper to configure the NSWindow (aspect, min size, title)
struct WindowConfigurator: NSViewRepresentable {
    private static let minContentSize = NSSize(width:200, height: 390) // HARD MIN: calculator minimum content size
    final class Coordinator: NSObject, NSWindowDelegate {
        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            // Clamp using a frame minimum derived from the hard content minimum
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
                // Persist/restore window frame
                win.setFrameAutosaveName("MainWindow") // optional built-in autosave
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

                // Aspect first
                win.aspectRatio = aspect

                // Enforce both content and frame minimums based on the hard content minimum
                win.contentMinSize = Self.minContentSize
                win.minSize = win.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minContentSize)).size
                // Start at minimum size
                win.setContentSize(Self.minContentSize)

                win.delegate = context.coordinator
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// WebView that loads the online simulator (no offline logic)
struct WebView: NSViewRepresentable {
    let urlString: String

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: cfg)
        view.pageZoom = 1.0
        view.setValue(false, forKey: "drawsBackground")

        // Smooth live resize
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .duringViewResize

        if let url = URL(string: urlString) {
            view.load(URLRequest(url: url))
        }
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        ZStack {
            // Invisible helper that configures the window
            WindowConfigurator().frame(width: 0, height: 0)
            WebView(urlString: "https://www.numworks.com/simulator/embed/")
                .ignoresSafeArea()
        }
    }
}
