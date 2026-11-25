import FleetKit
import Foundation

@MainActor
final class LocalAgentSupervisor {
    private var process: Process?
    private var shouldRun = false
    private let port = 9470

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var exposeOnNetwork: Bool {
        get { UserDefaults.standard.bool(forKey: "com.fleetstats.exposeLocalAgent") }
        set {
            let changed = newValue != UserDefaults.standard.bool(forKey: "com.fleetstats.exposeLocalAgent")
            UserDefaults.standard.set(newValue, forKey: "com.fleetstats.exposeLocalAgent")
            if changed && shouldRun {
                restart()
            }
        }
    }

    /// Loads or generates the local agent bearer token strictly from macOS Keychain.
    func localToken(for hostID: UUID) -> String {
        // Clean up any legacy plaintext UserDefaults token from earlier dev builds
        UserDefaults.standard.removeObject(forKey: "com.fleetstats.localAgentToken.v1")

        if let saved = KeychainStore.loadToken(for: hostID), saved.count >= 24 {
            return saved
        }
        let fresh = KeychainStore.generateRandomToken()
        KeychainStore.saveToken(fresh, for: hostID)
        return fresh
    }

    func start(token: String) {
        shouldRun = true
        lastToken = token
        launchIfNeeded(token: token)
    }

    func restart() {
        stop()
        if let tok = lastToken {
            shouldRun = true
            launchIfNeeded(token: tok)
        }
    }

    func stop() {
        shouldRun = false
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        process = nil
    }

    private var lastToken: String?

    private func resolveBinaryURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/fleetd")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let devPaths = [
            "/usr/local/bin/fleetd",
            NSHomeDirectory() + "/code/fleet-stats/agent/target/release/fleetd",
            NSHomeDirectory() + "/code/fleet-stats/agent/target/debug/fleetd"
        ]
        for p in devPaths where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    private func launchIfNeeded(token: String) {
        guard process == nil || !(process?.isRunning ?? false) else { return }
        guard let binURL = resolveBinaryURL() else {
            NSLog("FleetStats: fleetd helper binary not found")
            return
        }

        // Bind strictly to loopback, or loopback + Tailscale interface (never 0.0.0.0)
        let bindSpec = exposeOnNetwork ? "tailscale:\(port)" : "127.0.0.1:\(port)"
        let proc = Process()
        proc.executableURL = binURL
        proc.arguments = [
            "serve",
            "--bind", bindSpec,
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)"
        ]
        // Pass bearer token via environment variable rather than CLI args so it is not visible in `ps`
        var env = ProcessInfo.processInfo.environment
        env["FLEETD_TOKEN"] = token
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.shouldRun, let tok = self.lastToken else { return }
                self.process = nil
                try? await Task.sleep(for: .seconds(2))
                if self.shouldRun {
                    self.launchIfNeeded(token: tok)
                }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            NSLog("FleetStats: failed to launch fleetd: \(error.localizedDescription)")
        }
    }
}
