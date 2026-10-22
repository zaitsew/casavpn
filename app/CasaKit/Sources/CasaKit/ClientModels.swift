import Foundation

/// When a client stops working, as the edit form states it.
public enum ClientExpiry: Equatable, Sendable {
    case never
    /// A calendar moment. The form picks a day; the app ends that day at 23:59:59 local time.
    case date(Date)
    /// The countdown starts at the first connection (the panel stores a negative `expiryTime`).
    case afterFirstUse(days: Int)

    /// The panel's `expiryTime`: Unix milliseconds, 0 for never, negative for "N ms after first use".
    public var milliseconds: Int64 {
        switch self {
        case .never: 0
        case .date(let date): Int64((date.timeIntervalSince1970 * 1000).rounded())
        case .afterFirstUse(let days): -Int64(max(1, days)) * 86_400_000
        }
    }

    public init(expiryTime: Int64) {
        if expiryTime == 0 {
            self = .never
        } else if expiryTime < 0 {
            self = .afterFirstUse(days: max(1, Int((Double(-expiryTime) / 86_400_000).rounded())))
        } else {
            self = .date(Date(timeIntervalSince1970: Double(expiryTime) / 1000))
        }
    }

    /// The last second of the day that contains `date`.
    public static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}

extension Optional where Wrapped == ClientExpiry {
    var milliseconds: Int64 { self?.milliseconds ?? 0 }
}

/// What the add and edit forms edit. `originalEmail` is nil for a new client.
public struct ClientDraft: Equatable, Sendable {
    public static let bytesPerGB: Double = 1_073_741_824
    public static let visionFlow = "xtls-rprx-vision"

    public var originalEmail: String?
    public var email: String
    /// The traffic limit in GB; 0 means unlimited.
    public var totalGB: Double
    public var expiry: ClientExpiry?
    public var limitIp: Int
    public var enable: Bool
    /// Blank on a new client: the panel makes one.
    public var subId: String
    public var comment: String
    /// The inbounds a NEW client is attached to. An existing client keeps its inbounds.
    public var inboundIds: [Int]
    /// The flow a NEW client gets: `xtls-rprx-vision` on a VLESS Reality inbound, else empty.
    public var flow: String

    public init(
        originalEmail: String? = nil, email: String = "", totalGB: Double = 0, expiry: ClientExpiry? = .never,
        limitIp: Int = 0, enable: Bool = true, subId: String = "", comment: String = "",
        inboundIds: [Int] = [], flow: String = ""
    ) {
        self.originalEmail = originalEmail
        self.email = email
        self.totalGB = totalGB
        self.expiry = expiry
        self.limitIp = limitIp
        self.enable = enable
        self.subId = subId
        self.comment = comment
        self.inboundIds = inboundIds
        self.flow = flow
    }

    public init(editing detail: ClientDetail) {
        self.init(
            originalEmail: detail.email, email: detail.email,
            totalGB: Double(detail.totalBytes) / Self.bytesPerGB,
            expiry: ClientExpiry(expiryTime: detail.expiryTime),
            limitIp: detail.limitIp, enable: detail.enable, subId: detail.subId, comment: detail.comment,
            inboundIds: detail.inboundIds, flow: detail.flow
        )
    }

    public var isNew: Bool { originalEmail == nil }

    public var totalBytes: Int64 { Int64((max(0, totalGB) * Self.bytesPerGB).rounded()) }

    /// A message when the draft cannot be sent; nil when it can.
    public var validationError: String? {
        let name = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give the client a name." }
        if name.count > 64 { return "The name may have at most 64 characters." }
        if Self.hasForbiddenCharacter(name) { return "The name cannot contain spaces or slashes. Use a hyphen instead." }
        if totalGB < 0 { return "The traffic limit cannot be negative." }
        if totalGB > 1_000_000 { return "The traffic limit is too large." }
        if limitIp < 0 || limitIp > 1000 { return "The IP limit must be between 0 and 1000." }
        if case .afterFirstUse(let days)? = expiry, days < 1 || days > 36_500 { return "Days after first use must be between 1 and 36500." }
        let sub = subId.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.hasForbiddenCharacter(sub) { return "The subscription id cannot contain spaces or slashes." }
        if isNew && inboundIds.isEmpty { return "Pick at least one inbound." }
        return nil
    }

    /// The panel refuses these in a name or a subscription id (service.hasForbiddenClientChar):
    /// spaces and other white space, control characters, and slashes.
    static func hasForbiddenCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7f || $0 == "/" || $0 == "\\"
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    /// A random subscription id of 16 lowercase letters and digits, like the panel's own.
    public static func randomSubId() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }
}

/// One client in full (`GET /panel/api/clients/get/:email`).
public struct ClientDetail: Equatable, Sendable, Identifiable {
    public var email: String
    public var uuid: String
    public var subId: String
    public var enable: Bool
    public var totalBytes: Int64
    public var expiryTime: Int64
    public var limitIp: Int
    public var comment: String
    public var group: String
    public var flow: String
    public var inboundIds: [Int]
    public var usedBytes: Int64

    public var id: String { email }

    public init(
        email: String, uuid: String = "", subId: String = "", enable: Bool = true, totalBytes: Int64 = 0,
        expiryTime: Int64 = 0, limitIp: Int = 0, comment: String = "", group: String = "", flow: String = "",
        inboundIds: [Int] = [], usedBytes: Int64 = 0
    ) {
        self.email = email; self.uuid = uuid; self.subId = subId; self.enable = enable
        self.totalBytes = totalBytes; self.expiryTime = expiryTime; self.limitIp = limitIp
        self.comment = comment; self.group = group; self.flow = flow
        self.inboundIds = inboundIds; self.usedBytes = usedBytes
    }
}

/// The body of `POST /panel/api/clients/add` (`service.ClientCreatePayload`).
/// `id`, `password` and `auth` are left out: the panel makes them for the inbound's protocol.
struct ClientCreateBody: Encodable, Equatable {
    struct Client: Encodable, Equatable {
        var email: String
        var subId: String
        var flow: String
        var limitIp: Int
        var totalGB: Int64
        var expiryTime: Int64
        var enable: Bool
        var comment: String
        var tgId: Int64 = 0
        var reset: Int = 0
    }

    var client: Client
    var inboundIds: [Int]

    init(draft: ClientDraft) {
        client = Client(
            email: draft.email.trimmingCharacters(in: .whitespacesAndNewlines),
            subId: draft.subId.trimmingCharacters(in: .whitespacesAndNewlines),
            flow: draft.flow,
            limitIp: max(0, draft.limitIp),
            totalGB: draft.totalBytes,
            expiryTime: draft.expiry.milliseconds,
            enable: draft.enable,
            comment: draft.comment.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        inboundIds = draft.inboundIds
    }
}
