import AppKit
import Security

/// Installs new versions from GitHub Releases. A release has the tag "vX.Y.Z" and the
/// asset "MiniRec.zip". The new app must meet the running app's designated requirement,
/// so only builds signed with the same certificate install, and macOS keeps the
/// Screen Recording permission.
final class Updater {
    static let repo = "madeyexz/minirec"

    /// A new version, downloaded and checked, that waits until MiniRec is idle.
    private(set) var pending: URL?
    private var timer: Timer?
    private var checking = false
    var onReady: (() -> Void)?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        check(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func check(userInitiated: Bool) {
        guard !checking, pending == nil else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                guard let app = try await downloadNewerRelease() else {
                    if userInitiated { Self.message("MiniRec \(Self.currentVersion) is the latest version.") }
                    return
                }
                pending = app
                onReady?()
            } catch {
                if userInitiated { Self.message("MiniRec could not check for updates.", error.localizedDescription) }
            }
        }
    }

    /// Replaces this app with the pending version and opens it.
    func installPending() {
        guard let app = pending else { return }
        pending = nil
        do {
            let current = Bundle.main.bundleURL
            _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            Self.message("MiniRec could not install the update.", error.localizedDescription)
        }
    }

    private func downloadNewerRelease() async throws -> URL? {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        let api = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: api)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil } // no release yet
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard version.compare(Self.currentVersion, options: .numeric) == .orderedDescending,
              let asset = release.assets.first(where: { $0.name == "MiniRec.zip" }) else { return nil }

        let (zip, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MiniRec-\(version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: zip)

        let app = folder.appendingPathComponent("MiniRec.app")
        guard Self.isSignedLikeThisApp(app) else {
            throw NSError(domain: "MiniRec", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "MiniRec \(version) is not signed with the same certificate as this copy."])
        }
        return app
    }

    private static func isSignedLikeThisApp(_ app: URL) -> Bool {
        var me: SecStaticCode?, requirement: SecRequirement?, candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { return false }
        return SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private static func message(_ text: String, _ detail: String = "") {
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
