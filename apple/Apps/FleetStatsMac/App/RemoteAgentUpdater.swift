import AppKit
import FleetKit
import Foundation

struct RemoteUpdateResult: Sendable {
    let succeeded: Bool
    let needsInteractiveAuth: Bool
    let output: String
}

enum RemoteAgentUpdater {
    private static let installScriptURL = "https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/install.sh"
    private static let macAppUpdateScriptURL = "https://raw.githubusercontent.com/erskingardner/fleet-stats/main/scripts/update-macos-app.sh"

    /// Strictly validates an SSH host or username to block option injection (`-o...`) or shell metacharacters.
    static func isSafeSSHIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func sshDestination(address: String, username: String) -> String? {
        let cleanHost = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeSSHIdentifier(cleanHost) else { return nil }
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanUser.isEmpty {
            return cleanHost
        }
        guard isSafeSSHIdentifier(cleanUser) else { return nil }
        return "\(cleanUser)@\(cleanHost)"
    }

    /// Remote shell command executed on the target host.
    static func remoteCommand(os: OsKind, switchToZeroToken: Bool, nonInteractiveSudo: Bool) -> String {
        switch os {
        case .linux:
            let sudoCmd = nonInteractiveSudo ? "sudo -n" : "sudo"
            if switchToZeroToken {
                return "curl -fsSL \(installScriptURL) | \(sudoCmd) sh -s -- --no-token"
            } else {
                return "curl -fsSL \(installScriptURL) | \(sudoCmd) sh"
            }
        case .macos:
            return "curl -fsSL \(macAppUpdateScriptURL) | sh"
        }
    }

    /// Full copyable / interactive SSH command for Terminal.
    static func interactiveSSHCommand(
        address: String,
        username: String,
        os: OsKind,
        switchToZeroToken: Bool
    ) -> String {
        let target = sshDestination(address: address, username: username) ?? address
        let remote = remoteCommand(os: os, switchToZeroToken: switchToZeroToken, nonInteractiveSudo: false)
        return "ssh -t \(target) '\(remote)'"
    }

    /// Attempts a non-interactive SSH update (works seamlessly with Tailscale SSH or SSH keys + passwordless sudo).
    static func runNonInteractiveSSHUpdate(
        address: String,
        username: String,
        os: OsKind,
        switchToZeroToken: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> RemoteUpdateResult {
        guard let target = sshDestination(address: address, username: username) else {
            return RemoteUpdateResult(
                succeeded: false,
                needsInteractiveAuth: false,
                output: "Invalid SSH host or username."
            )
        }

        let remoteCmd = remoteCommand(os: os, switchToZeroToken: switchToZeroToken, nonInteractiveSudo: true)

        return await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=accept-new",
                "--",
                target,
                remoteCmd
            ]

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            let collector = OutputAccumulator()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                let combined = collector.append(chunk)
                onOutput(combined)
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                if !tail.isEmpty, let s = String(data: tail, encoding: .utf8) {
                    let combined = collector.append(s)
                    onOutput(combined)
                }

                let fullOutput = collector.current()
                let ok = proc.terminationStatus == 0
                let lower = fullOutput.lowercased()
                let needsInteractive = !ok && (
                    lower.contains("a password is required")
                    || lower.contains("permission denied")
                    || lower.contains("terminal is required")
                    || lower.contains("passphrase")
                    || lower.contains("sudo:")
                )
                return RemoteUpdateResult(
                    succeeded: ok,
                    needsInteractiveAuth: needsInteractive,
                    output: fullOutput
                )
            } catch {
                return RemoteUpdateResult(
                    succeeded: false,
                    needsInteractiveAuth: false,
                    output: "Failed to launch ssh: \(error.localizedDescription)"
                )
            }
        }.value
    }

    /// Launches Terminal.app with an interactive `.command` script so the user can enter sudo/SSH passwords natively.
    @MainActor
    static func openInTerminal(
        address: String,
        username: String,
        os: OsKind,
        switchToZeroToken: Bool
    ) -> Bool {
        guard let target = sshDestination(address: address, username: username) else {
            return false
        }
        let remote = remoteCommand(os: os, switchToZeroToken: switchToZeroToken, nonInteractiveSudo: false)
        let script = """
        #!/usr/bin/env bash
        echo "==> Updating FleetStats on \(target)..."
        ssh -t -- "\(target)" '\(remote)'
        echo ""
        echo "You can close this window now."
        rm -f "$0"
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetstats-update-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
            return NSWorkspace.shared.open(tmp)
        } catch {
            return false
        }
    }
}

private final class OutputAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        text.append(chunk)
        return text
    }

    func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}
