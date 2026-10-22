import Foundation

// Smaller models of the panel API: the Xray access log and the API tokens.

/// `service.LogEntry` (`POST /panel/api/server/xraylogs/:count`): one parsed line of Xray's access log.
public struct XrayLogEntry: Decodable, Equatable, Identifiable, Sendable {
    public enum Event: Int, Sendable {
        case direct = 0
        case blocked = 1
        case proxied = 2
    }

    public var date: Date?
    public var from: String
    public var to: String
    public var inbound: String
    public var outbound: String
    public var email: String
    public var event: Event
    public let id = UUID()

    public init(
        date: Date? = nil, from: String = "", to: String = "", inbound: String = "", outbound: String = "",
        email: String = "", event: Event = .proxied
    ) {
        self.date = date; self.from = from; self.to = to; self.inbound = inbound
        self.outbound = outbound; self.email = email; self.event = event
    }

    private enum CodingKeys: String, CodingKey {
        case dateTime = "DateTime", from = "FromAddress", to = "ToAddress", inbound = "Inbound"
        case outbound = "Outbound", email = "Email", event = "Event"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decodeIfPresent(String.self, forKey: .dateTime) ?? ""
        let parsed = JSONCoding.parseDate(text)
        // Go's zero time means "no timestamp in the line".
        date = parsed.flatMap { $0.timeIntervalSince1970 < 0 ? nil : $0 }
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        inbound = try c.decodeIfPresent(String.self, forKey: .inbound) ?? ""
        outbound = try c.decodeIfPresent(String.self, forKey: .outbound) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        event = Event(rawValue: try c.decodeIfPresent(Int.self, forKey: .event) ?? 2) ?? .proxied
    }

    public static func == (a: XrayLogEntry, b: XrayLogEntry) -> Bool {
        a.date == b.date && a.from == b.from && a.to == b.to && a.inbound == b.inbound
            && a.outbound == b.outbound && a.email == b.email && a.event == b.event
    }

    /// One line, as the log viewer shows it.
    public var line: String {
        let when = date.map { Self.timeFormatter.string(from: $0) } ?? ""
        let who = email.isEmpty ? "" : " [\(email)]"
        let route = outbound.isEmpty ? "" : " -> \(outbound)"
        return "\(when) \(from) \u{2192} \(to)\(route)\(who)".trimmingCharacters(in: .whitespaces)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// `panel.ApiTokenView` (`GET /panel/api/setting/apiTokens`, and the create answer, which alone carries `token`).
public struct ApiTokenInfo: Decodable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var token: String
    public var enabled: Bool
    public var createdAt: Int64
    public var scope: String
    public var expiresAt: Int64

    public init(id: Int, name: String, token: String = "", enabled: Bool = true, createdAt: Int64 = 0, scope: String = "admin", expiresAt: Int64 = 0) {
        self.id = id; self.name = name; self.token = token; self.enabled = enabled
        self.createdAt = createdAt; self.scope = scope; self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, token, enabled, createdAt, scope, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "admin"
        expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt) ?? 0
    }
}
