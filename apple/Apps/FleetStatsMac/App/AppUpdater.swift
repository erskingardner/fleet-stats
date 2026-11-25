import AppKit
import CryptoKit
import FleetKit
import Foundation
import Observation

struct AppReleaseInfo: Sendable, Equatable {
    let version: SemanticVersion
    let tagName: String
    let releaseNotes: String
    let htmlURL: URL
    let dmgURL: URL
    let checksumsURL: URL
}

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppReleaseInfo)
    case downloading(Double)
    case verifying
    case installing
    case failed(String)
}

@Observable
@MainActor
final class AppUpdater {
    private static let repo = "erskingardner/fleet-stats"
    private static let expectedTeamID = "8Z6Q2LZ77W"
    private static let expectedBundleID = "com.paper-robin.fleetstats"

    var phase: UpdatePhase = .idle
    var lastCheckedAt: Date?
    var dismissedVersionTag: String?
    var lastFetchedReleaseVersion: SemanticVersion?

    var autoCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckEnabled, forKey: "updater.autoCheck")
            if autoCheckEnabled {
                startBackgroundChecks()
            } else {
                backgroundTask?.cancel()
                backgroundTask = nil
            }
        }
    }

    var onUpdateAvailable: ((AppReleaseInfo) -> Void)?
    var onPrepareToRelaunch: (() -> Void)?

    private var backgroundTask: Task<Void, Never>?
    private var notifiedTag: String? {
        get { UserDefaults.standard.string(forKey: "updater.notifiedTag") }
        set { UserDefaults.standard.set(newValue, forKey: "updater.notifiedTag") }
    }

    var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var currentVersion: SemanticVersion {
        SemanticVersion(currentVersionString) ?? SemanticVersion("0.0.0")!
    }

    var availableRelease: AppReleaseInfo? {
        if case .available(let info) = phase {
            return info
        }
        return nil
    }

    /// Highest known version across this app bundle and the latest GitHub Release check.
    var latestKnownVersion: SemanticVersion {
        var best = currentVersion
        if let rel = availableRelease, rel.version > best {
            best = rel.version
        }
        if let fetched = lastFetchedReleaseVersion, fetched > best {
            best = fetched
        }
        return best
    }

    func isAgentVersionOutdated(_ rawVersion: String?) -> Bool {
        guard let rawVersion, let parsed = SemanticVersion(rawVersion) else { return false }
        return parsed < latestKnownVersion
    }

    var shouldShowBanner: Bool {
        guard let rel = availableRelease else { return false }
        return dismissedVersionTag != rel.tagName
    }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "updater.autoCheck") == nil {
            d.set(true, forKey: "updater.autoCheck")
        }
        self.autoCheckEnabled = d.bool(forKey: "updater.autoCheck")
        if let ts = d.object(forKey: "updater.lastCheckedAt") as? TimeInterval {
            self.lastCheckedAt = Date(timeIntervalSince1970: ts)
        }
        self.dismissedVersionTag = d.string(forKey: "updater.dismissedTag")
    }

    func startBackgroundChecks() {
        backgroundTask?.cancel()
        guard autoCheckEnabled else { return }
        backgroundTask = Task { [weak self] in
            // Wait briefly on launch so startup stays snappy
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await self?.checkForUpdates(userInitiated: false)
                // Re-check every 6 hours
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func dismissBanner(for tag: String) {
        dismissedVersionTag = tag
        UserDefaults.standard.set(tag, forKey: "updater.dismissedTag")
    }

    func checkForUpdates(userInitiated: Bool) async {
        if case .downloading = phase { return }
        if case .verifying = phase { return }
        if case .installing = phase { return }

        if userInitiated {
            phase = .checking
        }

        do {
            let release = try await fetchLatestRelease()
            let now = Date()
            lastCheckedAt = now
            lastFetchedReleaseVersion = release.version
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "updater.lastCheckedAt")

            if release.version > currentVersion {
                phase = .available(release)
                if !userInitiated && notifiedTag != release.tagName {
                    notifiedTag = release.tagName
                    onUpdateAvailable?(release)
                }
            } else {
                if userInitiated || availableRelease != nil {
                    phase = .upToDate
                }
            }
        } catch {
            if userInitiated {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func installAvailableUpdate() async {
        guard let release = availableRelease else { return }
        await downloadVerifyAndInstall(release)
    }

    private func fetchLatestRelease() async throws -> AppReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            throw UpdateError.message("Invalid GitHub release URL")
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("FleetStats/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.message("Could not reach GitHub Releases")
        }

        let decoded = try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        guard let semver = SemanticVersion(decoded.tag_name) else {
            throw UpdateError.message("Invalid release version: \(decoded.tag_name)")
        }
        guard let dmgAsset = decoded.assets.first(where: { $0.name == "FleetStats.dmg" }),
              let dmgURL = URL(string: dmgAsset.browser_download_url),
              dmgURL.scheme == "https" else {
            throw UpdateError.message("Release \(decoded.tag_name) does not include FleetStats.dmg")
        }
        guard let sumsAsset = decoded.assets.first(where: { $0.name == "SHA256SUMS.txt" }),
              let sumsURL = URL(string: sumsAsset.browser_download_url),
              sumsURL.scheme == "https" else {
            throw UpdateError.message("Release \(decoded.tag_name) is missing SHA256SUMS.txt")
        }
        let htmlURL = URL(string: decoded.html_url) ?? dmgURL

        return AppReleaseInfo(
            version: semver,
            tagName: decoded.tag_name,
            releaseNotes: decoded.body ?? "",
            htmlURL: htmlURL,
            dmgURL: dmgURL,
            checksumsURL: sumsURL
        )
    }

    private func downloadVerifyAndInstall(_ release: AppReleaseInfo) async {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("fleetstats-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let dmgDest = workDir.appendingPathComponent("FleetStats.dmg")
            let mountDir = workDir.appendingPathComponent("mount")
            let stagedApp = workDir.appendingPathComponent("FleetStats.app")

            // 1. Download SHA256SUMS.txt
            phase = .downloading(0.05)
            let (sumsData, sumsResp) = try await URLSession.shared.data(from: release.checksumsURL)
            guard let httpSums = sumsResp as? HTTPURLResponse, (200..<300).contains(httpSums.statusCode),
                  let sumsText = String(data: sumsData, encoding: .utf8) else {
                throw UpdateError.message("Failed downloading SHA256SUMS.txt")
            }
            guard let expectedSHA = parseChecksum(for: "FleetStats.dmg", in: sumsText) else {
                throw UpdateError.message("No checksum found for FleetStats.dmg")
            }

            // 2. Download FleetStats.dmg with progress
            try await downloadFile(from: release.dmgURL, to: dmgDest) { progress in
                Task { @MainActor [weak self] in
                    self?.phase = .downloading(0.05 + progress * 0.85)
                }
            }

            // 3. Verify SHA-256 checksum
            phase = .verifying
            let actualSHA = try sha256Hex(of: dmgDest)
            guard actualSHA.lowercased() == expectedSHA.lowercased() else {
                throw UpdateError.message("SHA-256 checksum mismatch! Update aborted.")
            }

            // 4. Mount DMG, verify Apple Developer ID code signature & Team ID, and stage .app
            try fm.createDirectory(at: mountDir, withIntermediateDirectories: true)
            try runTool("/usr/bin/hdiutil", args: [
                "attach", "-nobrowse", "-readonly", "-mountpoint", mountDir.path, dmgDest.path
            ])
            defer {
                _ = try? runTool("/usr/bin/hdiutil", args: ["detach", mountDir.path, "-force"])
            }

            let mountedApp = mountDir.appendingPathComponent("FleetStats.app")
            guard fm.fileExists(atPath: mountedApp.path) else {
                throw UpdateError.message("FleetStats.app not found inside DMG")
            }

            // Strict signature + Developer ID Team + Bundle ID verification
            try verifySignedBundle(at: mountedApp)

            // Copy verified app out of DMG before detaching
            try fm.copyItem(at: mountedApp, to: stagedApp)

            // 5. Swap running bundle & relaunch
            phase = .installing
            let targetAppURL = Bundle.main.bundleURL
            try launchSwapScript(stagedApp: stagedApp, targetApp: targetAppURL, workDir: workDir)

            onPrepareToRelaunch?()
            NSApp.terminate(nil)
        } catch {
            try? fm.removeItem(at: workDir)
            phase = .failed(error.localizedDescription)
        }
    }

    private func verifySignedBundle(at appURL: URL) throws {
        try runTool("/usr/bin/codesign", args: ["--verify", "--deep", "--strict", appURL.path])
        let details = try runToolCapturingOutput("/usr/bin/codesign", args: ["-dv", "--verbose=4", appURL.path])
        guard details.contains("Identifier=\(Self.expectedBundleID)") else {
            throw UpdateError.message("Downloaded app bundle ID does not match \(Self.expectedBundleID)")
        }
        guard details.contains("TeamIdentifier=\(Self.expectedTeamID)") else {
            throw UpdateError.message("Downloaded app is not signed by expected Developer Team (\(Self.expectedTeamID))")
        }
    }

    private func launchSwapScript(stagedApp: URL, targetApp: URL, workDir: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = workDir.appendingPathComponent("apply-update.sh")
        let targetParent = targetApp.deletingLastPathComponent().path
        let needsElevation = !FileManager.default.isWritableFile(atPath: targetParent)

        let swapBlock: String
        if needsElevation {
            swapBlock = """
            /usr/bin/osascript -e "do shell script \\"rm -rf '\(targetApp.path)' && mv '\(stagedApp.path)' '\(targetApp.path)' && xattr -dr com.apple.quarantine '\(targetApp.path)' 2>/dev/null || true\\" with administrator privileges"
            """
        } else {
            swapBlock = """
            rm -rf "\(targetApp.path)"
            mv "\(stagedApp.path)" "\(targetApp.path)"
            xattr -dr com.apple.quarantine "\(targetApp.path)" 2>/dev/null || true
            """
        }

        let script = """
        #!/bin/sh
        set -e
        while kill -0 \(pid) 2>/dev/null; do
          sleep 0.2
        done
        \(swapBlock)
        open -n "\(targetApp.path)"
        rm -rf "\(workDir.path)"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [scriptURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = DownloadTaskDelegate(
                destination: destination,
                onProgress: onProgress,
                continuation: continuation
            )
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 300
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    private func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 256 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func parseChecksum(for filename: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2 {
                let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                if name == filename {
                    return String(parts[0])
                }
            }
        }
        return nil
    }

    private func runTool(_ path: String, args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.message(errText.isEmpty ? "\(path) exited with \(proc.terminationStatus)" : errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func runToolCapturingOutput(_ path: String, args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out + "\n" + err
    }
}

private final class DownloadTaskDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        onProgress(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.lock()
            moveError = UpdateError.message("Failed downloading FleetStats.dmg (HTTP \(http.statusCode))")
            lock.unlock()
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
            onProgress(1.0)
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let err = error ?? moveError
        lock.unlock()

        if let err {
            cont?.resume(throwing: err)
        } else {
            cont?.resume(returning: ())
        }
    }
}

private enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}

private struct GitHubReleaseDTO: Decodable {
    let tag_name: String
    let html_url: String
    let body: String?
    let assets: [AssetDTO]

    struct AssetDTO: Decodable {
        let name: String
        let browser_download_url: String
    }
}
