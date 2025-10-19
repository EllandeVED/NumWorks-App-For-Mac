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
                showInfoAlert(
                    title: "Can’t Check for Updates",
                    text: "Make sure you’re connected to the internet and try again."
                )
            }
        }
    }

    // MARK: - Impl

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String?
    }

    private func fetchLatest() async throws -> GitHubRelease {
        var req = URLRequest(url: latestAPI, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func handle(remote: GitHubRelease, userInitiated: Bool) throws {
        let remoteTag = remote.tag_name
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        if !userInitiated, lastAlertedVersion == remoteTag { return } // suppress only for auto/launch checks

        if isRemote(remoteTag, newerThan: current) {
            lastAlertedVersion = remoteTag
            showUpdateAlert(remoteTag: remoteTag, page: URL(string: remote.html_url ?? "") ?? releasesPage)
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

    // MARK: - Alerts

    private func showUpdateAlert(remoteTag: String, page: URL) {
        let alert = NSAlert()
        alert.messageText = "A New Version is Available"
        alert.informativeText = "Version \(remoteTag) is available. Would you like to download it?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        
        // Create small gray text as accessory view
        let noteLabel = NSTextField(labelWithString: "Make sure you delete the old app before downloading the new one.")
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.alignment = .center
        noteLabel.preferredMaxLayoutWidth = 240
        noteLabel.lineBreakMode = .byWordWrapping
        
        // Reduce spacing with a container view
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        noteLabel.frame = NSRect(x: 0, y: 0, width: 240, height: 30)
        container.addSubview(noteLabel)
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
}
