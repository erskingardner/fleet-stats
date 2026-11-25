import Darwin
import FleetKit
import Foundation

@MainActor
final class LocalAgentSupervisor {
    private var process: Process?
    private var shouldRun = false
    private(set) var activePort: Int = 9470
    private let preferredPort = 9470

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    var onPortChanged: ((Int) -> Void)?

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
        UserDefaults.standard.removeObject(forKey: "com.fleetstats.localAgentToken.v1")

        if let saved = KeychainStore.loadToken(for: hostID), saved.count >= 24 {
            return saved
        }
        let fresh = KeychainStore.generateRandomToken()
        KeychainStore.saveToken(fresh, for: hostID)
        return fresh
    }

    @discardableResult
    func start(token: String) -> Int {
        shouldRun = true
        lastToken = token
        let port = pickAvailablePort(startingAt: preferredPort)
        activePort = port
        launchIfNeeded(token: token, port: port)
        return port
    }

    func restart() {
        stop()
        if let tok = lastToken {
            shouldRun = true
            let port = pickAvailablePort(startingAt: preferredPort)
            activePort = port
            onPortChanged?(port)
            launchIfNeeded(token: tok, port: port)
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

    /// Finds an available TCP port on 127.0.0.1 starting at `preferredPort` (e.g. 9470, 9471, ...),
    /// preventing collisions when multiple macOS users run FleetStats simultaneously or a standalone
    /// launchd fleetd already occupies 9470.
    private func pickAvailablePort(startingAt start: Int) -> Int {
        for candidate in start..<(start + 64) {
            if Self.isLoopbackPortAvailable(UInt16(candidate)) {
                return candidate
            }
        }
        return start
    }

    private static func isLoopbackPortAvailable(_ port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

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

    private func launchIfNeeded(token: String, port: Int) {
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
                    let nextPort = self.pickAvailablePort(startingAt: self.preferredPort)
                    if nextPort != self.activePort {
                        self.activePort = nextPort
                        self.onPortChanged?(nextPort)
                    }
                    self.launchIfNeeded(token: tok, port: nextPort)
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
