import Foundation

public struct SemanticVersion: Comparable, Sendable, Equatable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ raw: String) {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .split(separator: "-", maxSplits: 1).first
            .map(String.init) ?? ""

        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.major = parts[0]
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
