import Foundation

public enum FleetClientError: Error, LocalizedError, Sendable {
    case invalidURL
    case unauthorized
    case httpStatus(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid host address"
        case .unauthorized: "Invalid bearer token (401)"
        case .httpStatus(let code): "HTTP error \(code)"
        case .network(let msg): msg
        }
    }
}

public final class FleetClient: Sendable {
    private let session: URLSession
    private let streamSession: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)

        let scfg = URLSessionConfiguration.default
        scfg.timeoutIntervalForRequest = 45
        scfg.timeoutIntervalForResource = 60 * 60 * 24
        scfg.waitsForConnectivity = false
        self.streamSession = URLSession(configuration: scfg)
    }

    public func fetchHealth(host: FleetHostConfig, token: String) async throws -> HealthResponse {
        try await get(path: "/v1/health", host: host, token: token)
    }

    public func fetchSnapshot(host: FleetHostConfig, token: String) async throws -> HostSnapshot {
        try await get(path: "/v1/snapshot", host: host, token: token)
    }

    public func fetchHistory(
        host: FleetHostConfig,
        token: String,
        window: HistoryWindow
    ) async throws -> HistoryResponse {
        let w = window == .live ? "15m" : window.rawValue
        return try await get(path: "/v1/history?window=\(w)", host: host, token: token)
    }

    public func fetchEvents(
        host: FleetHostConfig,
        token: String,
        limit: Int = 60
    ) async throws -> [FleetEvent] {
        let resp: EventsResponse = try await get(path: "/v1/events?limit=\(limit)", host: host, token: token)
        return resp.events
    }

    public func fetchAlertConfig(host: FleetHostConfig, token: String) async throws -> AlertConfig {
        try await get(path: "/v1/alerts/config", host: host, token: token)
    }

    public func updateAlertConfig(
        host: FleetHostConfig,
        token: String,
        config: AlertConfig
    ) async throws -> AlertConfig {
        guard let base = host.baseURL, let url = URL(string: "/v1/alerts/config", relativeTo: base) else {
            throw FleetClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try FleetJSON.makeEncoder().encode(config)

        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)
        return try FleetJSON.makeDecoder().decode(AlertConfig.self, from: data)
    }

    public func stream(host: FleetHostConfig, token: String) -> AsyncThrowingStream<StreamMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let base = host.baseURL, let url = URL(string: "/v1/stream", relativeTo: base) else {
                    continuation.finish(throwing: FleetClientError.invalidURL)
                    return
                }
                var req = URLRequest(url: url)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                req.cachePolicy = .reloadIgnoringLocalCacheData

                do {
                    let (bytes, response) = try await streamSession.bytes(for: req)
                    try validateHTTP(response)
                    let decoder = FleetJSON.makeDecoder()

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                        if let msg = try? decoder.decode(StreamMessage.self, from: data) {
                            continuation.yield(msg)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func get<T: Decodable>(path: String, host: FleetHostConfig, token: String) async throws -> T {
        guard let base = host.baseURL, let url = URL(string: path, relativeTo: base) else {
            throw FleetClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try validateHTTP(response)
        return try FleetJSON.makeDecoder().decode(T.self, from: data)
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FleetClientError.network("Non-HTTP response")
        }
        if http.statusCode == 401 {
            throw FleetClientError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FleetClientError.httpStatus(http.statusCode)
        }
    }
}
