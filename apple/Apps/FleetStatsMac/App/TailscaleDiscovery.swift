import Foundation

struct DiscoveredTailscalePeer: Identifiable, Sendable, Equatable {
    let id: String
    let hostName: String
    let dnsName: String
    let ipv4: String
    let os: String
    let isOnline: Bool
    var fleetdDetected: Bool

    var preferredAddress: String {
        let trimmed = dnsName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? ipv4 : trimmed
    }

    var isLinux: Bool {
        os.lowercased() == "linux"
    }

    var sshCopyTokenCommand: String {
        let target = preferredAddress
        if isLinux {
            return "ssh \(target) 'sudo fleetd --config /etc/fleetd/config.toml print-token' | pbcopy"
        } else {
            return "ssh \(target) 'fleetd print-token' | pbcopy"
        }
    }
}

enum TailscaleDiscovery {
    private static let cliPaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale"
    ]

    static func discoverPeers(port: Int = 9470) async -> [DiscoveredTailscalePeer] {
        guard let cli = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }

        let rawPeers: [DiscoveredTailscalePeer] = await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cli)
            proc.arguments = ["status", "--json"]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else { return [] }
                return parseTailscaleStatus(data)
            } catch {
                return []
            }
        }.value

        // Probe online peers in parallel to detect running fleetd instances (401/200 on :9470)
        return await withTaskGroup(of: DiscoveredTailscalePeer.self) { group in
            for peer in rawPeers {
                group.addTask {
                    var updated = peer
                    if peer.isOnline {
                        updated.fleetdDetected = await probeFleetd(ip: peer.ipv4, port: port)
                    }
                    return updated
                }
            }
            var results: [DiscoveredTailscalePeer] = []
            for await peer in group {
                results.append(peer)
            }
            return results.sorted { lhs, rhs in
                if lhs.fleetdDetected != rhs.fleetdDetected {
                    return lhs.fleetdDetected && !rhs.fleetdDetected
                }
                if lhs.isOnline != rhs.isOnline {
                    return lhs.isOnline && !rhs.isOnline
                }
                return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
            }
        }
    }

    private static func probeFleetd(ip: String, port: Int) async -> Bool {
        guard !ip.isEmpty, let url = URL(string: "http://\(ip):\(port)/v1/health") else {
            return false
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            if http.statusCode == 401 {
                if let text = String(data: data, encoding: .utf8), text.contains("unauthorized") {
                    return true
                }
            }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    private static func parseTailscaleStatus(_ data: Data) -> [DiscoveredTailscalePeer] {
        guard let decoded = try? JSONDecoder().decode(TailscaleStatusDTO.self, from: data),
              let peerMap = decoded.Peer else {
            return []
        }
        var peers: [DiscoveredTailscalePeer] = []
        for (key, dto) in peerMap {
            let os = dto.OS ?? ""
            let lowerOS = os.lowercased()
            // Focus on Mac & Linux fleet machines (skip phones/tablets)
            guard lowerOS == "macos" || lowerOS == "linux" else { continue }
            let ipv4 = dto.TailscaleIPs?.first(where: { !$0.contains(":") }) ?? ""
            guard !ipv4.isEmpty else { continue }
            let dns = (dto.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let host = (dto.HostName ?? dns.split(separator: ".").first.map(String.init) ?? ipv4)
            peers.append(DiscoveredTailscalePeer(
                id: key,
                hostName: host,
                dnsName: dns,
                ipv4: ipv4,
                os: os,
                isOnline: dto.Online ?? false,
                fleetdDetected: false
            ))
        }
        return peers
    }
}

private struct TailscaleStatusDTO: Decodable {
    let Peer: [String: PeerDTO]?

    struct PeerDTO: Decodable {
        let HostName: String?
        let DNSName: String?
        let OS: String?
        let Online: Bool?
        let TailscaleIPs: [String]?
    }
}
