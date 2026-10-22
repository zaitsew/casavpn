import Foundation

public enum Severity: String, Codable, Sendable, CaseIterable {
    case critical, warning, info

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Severity(rawValue: raw) ?? .info
    }
}

/// One entry of the relay's alert history.
public struct VPNAlert: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var severity: Severity
    public var title: String
    public var body: String
    public var at: Date
    public var source: String

    public init(id: String, kind: String, severity: Severity, title: String, body: String, at: Date, source: String) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.body = body
        self.at = at
        self.source = source
    }

    /// The part of `kind` before the first dot: `client.traffic` -> `client`.
    public var group: String { String(kind.split(separator: ".").first ?? "") }
}

public enum MonitorStatus: String, Codable, Sendable {
    case up, down, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MonitorStatus(rawValue: raw) ?? .unknown
    }
}

/// The Worker's view of the VPN port.
public struct Monitor: Codable, Equatable, Sendable {
    public var status: MonitorStatus
    public var since: Date?
    public var lastCheck: Date?
    public var ip: String?
    public var target: String?

    public init(status: MonitorStatus, since: Date? = nil, lastCheck: Date? = nil, ip: String? = nil, target: String? = nil) {
        self.status = status
        self.since = since
        self.lastCheck = lastCheck
        self.ip = ip
        self.target = target
    }

    private enum CodingKeys: String, CodingKey { case status, since, lastCheck, ip, target }

    // Dates are optional here: a fresh relay answers `unknown` with no timestamps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(MonitorStatus.self, forKey: .status) ?? .unknown
        since = try? c.decodeIfPresent(Date.self, forKey: .since)
        lastCheck = try? c.decodeIfPresent(Date.self, forKey: .lastCheck)
        ip = try c.decodeIfPresent(String.self, forKey: .ip)
        target = try c.decodeIfPresent(String.self, forKey: .target)
    }
}

public struct AlertsResponse: Decodable, Equatable, Sendable {
    public var alerts: [VPNAlert]
    public var monitor: Monitor?
}

/// The answer to `POST /v1/test` and `POST /v1/events`.
public struct PushResult: Decodable, Equatable, Sendable {
    public var id: String?
    public var pushed: Int?
    public var deduped: Bool?
}

public enum PushEnvironment: String, Codable, Sendable {
    case sandbox, production

    /// Debug builds register with APNs' sandbox, TestFlight and App Store builds with production.
    public static var current: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

public struct DeviceRegistration: Codable, Equatable, Sendable {
    public var token: String
    public var environment: PushEnvironment
    public var name: String

    public static let maxNameLength = 40

    public init(token: String, environment: PushEnvironment, name: String) {
        self.token = token
        self.environment = environment
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
    }
}

/// APNs device token bytes as lowercase hex, the form the relay stores.
public enum DeviceToken {
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func isHex(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isHexDigit }
    }
}
