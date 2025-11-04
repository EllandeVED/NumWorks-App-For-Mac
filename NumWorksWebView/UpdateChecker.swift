import Foundation
import AppKit

/// Simple “check GitHub Releases for a newer version” helper.
@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    // Your repo
    private let owner = "EllandeVED"
    private let repo  = "NumWorks-App-For-Mac"

    // Endpoints
    private var latestAPI: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }
    private var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    // Prevent duplicate alerts during one run
    private var lastAlertedVersion: String?

    /// Call at launch. Silent on errors / up-to-date.
    func checkOnLaunch() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let remote = try await fetchLatest()
                try handle(remote: remote, userInitiated: false)
            } catch {
                // Quiet on launch; no-op
            }
        }
    }

    /// Call from Settings → “Check for Updates…”. Shows alerts for all outcomes.
    func checkNow() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let remote = try await fetchLatest()
                try handle(remote: remote, userInitiated: true)
            } catch {
                showNetworkErrorAlert(error)
            }
        }
    }

    // MARK: - Impl

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String?
        let body: String?
    }

    private func fetchLatest() async throws -> GitHubRelease {
        var req = URLRequest(url: latestAPI, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = resp as? HTTPURLResponse {
                let err = NSError(domain: "HTTPStatus", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned status code \(http.statusCode)"])
                throw err
            } else {
                throw URLError(.badServerResponse)
            }
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func handle(remote: GitHubRelease, userInitiated: Bool) throws {
        let remoteTag = remote.tag_name
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        if !userInitiated, lastAlertedVersion == remoteTag { return } // suppress only for auto/launch checks

        if isRemote(remoteTag, newerThan: current) {
            lastAlertedVersion = remoteTag
            let notes = remote.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            showUpdateAlert(remoteTag: remoteTag, page: URL(string: remote.html_url ?? "") ?? releasesPage, notes: notes)
        } else if userInitiated {
            showInfoAlert(title: "You’re Up To Date", text: "You have the latest version (\(current)).")
        }
    }

    /// Compare semantic versions
    private func isRemote(_ remote: String, newerThan local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .compactMap { Int($0) }
        }
        let r = parts(remote)
        let l = parts(local)
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // MARK: - Release Notes Font Preferences (macOS 15+)
    private enum RNFontKeys {
        static let name = "ReleaseNotesFontName"
        static let size = "ReleaseNotesFontSize"
        static let mono = "ReleaseNotesFontMonospaced"
    }

    /// Set a custom font for the release notes viewer. Pass `nil` to keep current for a given parameter.
    static func setReleaseNotesFont(name: String? = nil, size: CGFloat? = nil, monospaced: Bool? = nil) {
        let d = UserDefaults.standard
        if let name { d.set(name, forKey: RNFontKeys.name) }
        if let size { d.set(size, forKey: RNFontKeys.size) }
        if let monospaced { d.set(monospaced, forKey: RNFontKeys.mono) }
    }

    /// Reset to defaults.
    static func resetReleaseNotesFont() {
        let d = UserDefaults.standard
        d.removeObject(forKey: RNFontKeys.name)
        d.removeObject(forKey: RNFontKeys.size)
        d.removeObject(forKey: RNFontKeys.mono)
    }

    /// Current configured font for release notes.
    static func currentReleaseNotesFont() -> NSFont {
        let d = UserDefaults.standard
        let defaultSize: CGFloat = 12
        let size = d.object(forKey: RNFontKeys.size) as? CGFloat ?? defaultSize
        let useMono = d.object(forKey: RNFontKeys.mono) as? Bool ?? false
        if let name = d.string(forKey: RNFontKeys.name), let custom = NSFont(name: name, size: size) {
            return custom
        }
        if useMono { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return .systemFont(ofSize: size)
    }

    // MARK: - Alerts

    private func showUpdateAlert(remoteTag: String, page: URL, notes: String?) {
        let alert = NSAlert()
        alert.messageText = "A New Version is Available"
        alert.informativeText = "Version \(remoteTag) is available. Would you like to download it?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        // ---- Build accessory view using explicit frames (NSAlert often ignores Auto Layout) ----
        let totalWidth: CGFloat = 420
        let padding: CGFloat = 12
        let spacing: CGFloat = 8
        let innerWidth = totalWidth - 2 * padding

        // Small gray reminder label (wrapped)
        let reminder = "Make sure you delete the old app before downloading the new one."
        let reminderLabel = NSTextField(labelWithString: reminder)
        reminderLabel.font = .systemFont(ofSize: 10)
        reminderLabel.textColor = .secondaryLabelColor
        reminderLabel.alignment = .center
        reminderLabel.lineBreakMode = .byWordWrapping

        // Measure reminder height
        let remAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10)]
        let remBounds = (reminder as NSString).boundingRect(
            with: NSSize(width: innerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: remAttr
        )
        let reminderHeight = ceil(remBounds.height)

        // Optional release notes (Markdown/plain) in a scroll view
        let notesHeight: CGFloat = (notes?.isEmpty == false) ? 200 : 0

        // Compute total height
        let totalHeight: CGFloat = padding + reminderHeight + (notesHeight > 0 ? spacing + notesHeight : 0) + padding

        let container = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

        // Place reminder label
        var cursorY = totalHeight - padding - reminderHeight
        reminderLabel.frame = NSRect(x: padding, y: cursorY, width: innerWidth, height: reminderHeight)
        container.addSubview(reminderLabel)

        // Add notes if present
        if let notes, !notes.isEmpty {
            cursorY -= (spacing + notesHeight)
            let scrollFrame = NSRect(x: padding, y: cursorY, width: innerWidth, height: notesHeight)
            let scrollView = NSScrollView(frame: scrollFrame)
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.borderType = .bezelBorder
            scrollView.autohidesScrollers = true

            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: innerWidth, height: notesHeight))
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 6, height: 8)
            textView.textContainer?.lineFragmentPadding = 4

            // Paste the release body exactly as authored (preserve line breaks), no Markdown/HTML processing
            let font = Self.currentReleaseNotesFont()
            let raw = notes
            let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

            textView.isRichText = false
            textView.usesRuler = false
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.textContainer?.widthTracksTextView = true

            textView.string = text
            textView.font = font
            textView.textColor = .labelColor

            textView.typingAttributes = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]

            scrollView.documentView = textView
            container.addSubview(scrollView)
        }

        alert.accessoryView = container

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    private func showInfoAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showNetworkErrorAlert(_ error: Error) {
        let ns = error as NSError
        let code = ns.code
        let domain = ns.domain
        let message = ns.localizedDescription

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can’t Check for Updates"
        alert.informativeText = "Make sure you’re connected to the internet and try again.\n\nError: \(domain) (code \(code))\n\(message)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
