import Foundation

enum PeerFleetdStatus: Sendable, Equatable {
    case none
    /// fleetd responded 200 OK in zero-token Tailscale-trust mode (1-click Add!)
    case ready
    /// fleetd responded 401 Unauthorized (requires optional bearer token)
    case requiresToken
}

struct DiscoveredTailscalePeer: Identifiable, Sendable, Equatable {
    let id: String
    let hostName: String
    let dnsName: String
    let ipv4: String
    let os: String
    let isOnline: Bool
    var fleetdStatus: PeerFleetdStatus
    var detectedPort: Int

    var fleetdDetected: Bool {
        fleetdStatus != .none
    }

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

        // Probe online peers in parallel across 9470..9475 (handles multi-user Macs where
        // Fast User Switching shifts the local helper port above 9470).
        var candidatePorts = [port]
        for p in 9470...9475 where !candidatePorts.contains(p) {
            candidatePorts.append(p)
        }
        let portsToProbe = candidatePorts

        return await withTaskGroup(of: DiscoveredTailscalePeer.self) { group in
            for peer in rawPeers {
                group.addTask {
                    var updated = peer
                    if peer.isOnline {
                        let (status, foundPort) = await probeFleetdPorts(ip: peer.ipv4, ports: portsToProbe)
                        updated.fleetdStatus = status
                        updated.detectedPort = foundPort
                    }
                    return updated
                }
            }
            var results: [DiscoveredTailscalePeer] = []
            for await peer in group {
                results.append(peer)
            }
            return results.sorted { lhs, rhs in
                let lhsRank = sortRank(lhs)
                let rhsRank = sortRank(rhs)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.hostName.localizedCaseInsensitiveCompare(rhs.hostName) == .orderedAscending
            }
        }
    }

    private static func sortRank(_ peer: DiscoveredTailscalePeer) -> Int {
        switch peer.fleetdStatus {
        case .ready: 0
        case .requiresToken: 1
        case .none: peer.isOnline ? 2 : 3
        }
    }

    private static func probeFleetdPorts(ip: String, ports: [Int]) async -> (PeerFleetdStatus, Int) {
        let defaultPort = ports.first ?? 9470
        guard !ip.isEmpty else { return (.none, defaultPort) }

        return await withTaskGroup(of: (Int, PeerFleetdStatus).self) { group in
            for p in ports {
                group.addTask {
                    let st = await probeFleetd(ip: ip, port: p)
                    return (p, st)
                }
            }
            var bestReady: Int?
            var bestToken: Int?
            for await (p, st) in group {
                switch st {
                case .ready:
                    bestReady = min(bestReady ?? p, p)
                case .requiresToken:
                    bestToken = min(bestToken ?? p, p)
                case .none:
                    break
                }
            }
            if let readyPort = bestReady {
                return (.ready, readyPort)
            }
            if let tokenPort = bestToken {
                return (.requiresToken, tokenPort)
            }
            return (.none, defaultPort)
        }
    }

    private static func probeFleetd(ip: String, port: Int) async -> PeerFleetdStatus {
        guard !ip.isEmpty, let url = URL(string: "http://\(ip):\(port)/v1/health") else {
            return .none
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("1", forHTTPHeaderField: "X-FleetStats")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .none }
            let text = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 200 && text.contains("\"status\"") {
                return .ready
            }
            if http.statusCode == 401 && text.contains("unauthorized") {
                return .requiresToken
            }
            return .none
        } catch {
            return .none
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
                fleetdStatus: .none,
                detectedPort: 9470
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
