import Foundation

// Models for the inbounds routes of 3x-ui v3.10.2:
//   internal/database/model/model.go   Inbound  -> GET /panel/api/inbounds/list/slim, /get/:id
//   internal/xray/client_traffic.go    ClientTraffic (the `clientStats` of an inbound)
// `settings`, `streamSettings` and `sniffing` are JSON documents stored in strings.

/// A JSON value, just enough to accept a field that is a string in one panel version and an object in another.
enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var any: Any {
        switch self {
        case .string(let v): v
        case .number(let v): v
        case .bool(let v): v
        case .null: NSNull()
        case .array(let v): v.map(\.any)
        case .object(let v): v.mapValues(\.any)
        }
    }
}

/// A string field that may arrive as a string (v3.10.2) or as an embedded object.
struct JSONText: Decodable {
    var text: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { text = ""; return }
        if let string = try? c.decode(String.self) { text = string; return }
        let value = try c.decode(JSONValue.self)
        let data = (try? JSONSerialization.data(withJSONObject: value.any, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }
}

enum JSONDocument {
    static func object(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8), !text.isBlank else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The REALITY half of an inbound's `streamSettings` that the app shows and edits.
public struct RealityConfig: Equatable, Sendable {
    public var target: String
    public var serverNames: [String]
    public var shortIds: [String]
    public var privateKey: String
    public var publicKey: String
    public var fingerprint: String

    public init(
        target: String = "", serverNames: [String] = [], shortIds: [String] = [],
        privateKey: String = "", publicKey: String = "", fingerprint: String = "chrome"
    ) {
        self.target = target; self.serverNames = serverNames; self.shortIds = shortIds
        self.privateKey = privateKey; self.publicKey = publicKey; self.fingerprint = fingerprint
    }
}

public struct Inbound: Decodable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var remark: String
    public var enable: Bool
    public var port: Int
    public var protocolName: String
    public var listen: String
    public var tag: String
    public var up: Int64
    public var down: Int64
    /// The traffic limit in bytes; 0 means unlimited.
    public var total: Int64
    public var expiryTime: Int64
    public var disableFlow: Bool
    public var settings: String
    public var streamSettings: String
    public var clientStats: [ClientTraffic]

    public init(
        id: Int, remark: String, enable: Bool = true, port: Int, protocolName: String = "vless", listen: String = "",
        tag: String = "", up: Int64 = 0, down: Int64 = 0, total: Int64 = 0, expiryTime: Int64 = 0,
        disableFlow: Bool = false, settings: String = "", streamSettings: String = "", clientStats: [ClientTraffic] = []
    ) {
        self.id = id; self.remark = remark; self.enable = enable; self.port = port; self.protocolName = protocolName
        self.listen = listen; self.tag = tag; self.up = up; self.down = down; self.total = total
        self.expiryTime = expiryTime; self.disableFlow = disableFlow; self.settings = settings
        self.streamSettings = streamSettings; self.clientStats = clientStats
    }

    private enum CodingKeys: String, CodingKey {
        case id, remark, enable, port, listen, tag, up, down, total, expiryTime, disableFlow
        case settings, streamSettings, clientStats
        case protocolName = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        remark = try c.decodeIfPresent(String.self, forKey: .remark) ?? ""
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName) ?? ""
        listen = try c.decodeIfPresent(String.self, forKey: .listen) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        up = try c.decodeIfPresent(Int64.self, forKey: .up) ?? 0
        down = try c.decodeIfPresent(Int64.self, forKey: .down) ?? 0
        total = try c.decodeIfPresent(Int64.self, forKey: .total) ?? 0
        expiryTime = try c.decodeIfPresent(Int64.self, forKey: .expiryTime) ?? 0
        disableFlow = try c.decodeIfPresent(Bool.self, forKey: .disableFlow) ?? false
        settings = (try? c.decodeIfPresent(JSONText.self, forKey: .settings))?.text ?? ""
        streamSettings = (try? c.decodeIfPresent(JSONText.self, forKey: .streamSettings))?.text ?? ""
        clientStats = (try? c.decodeIfPresent([ClientTraffic].self, forKey: .clientStats)) ?? []
    }

    public var usedBytes: Int64 { up + down }

    /// The traffic limit in bytes, or nil when unlimited.
    public var limitBytes: Int64? { total > 0 ? total : nil }

    /// Clients on this inbound: the settings' client list, or the traffic rows when the list is stripped.
    public var clientCount: Int {
        let listed = (JSONDocument.object(settings)?["clients"] as? [Any])?.count ?? 0
        return max(listed, clientStats.count)
    }

    /// `tcp`, `ws`, `grpc`, `xhttp`... from `streamSettings.network`; empty when absent.
    public var network: String {
        (JSONDocument.object(streamSettings)?["network"] as? String) ?? ""
    }

    /// `none`, `tls` or `reality`.
    public var security: String {
        (JSONDocument.object(streamSettings)?["security"] as? String) ?? "none"
    }

    public var reality: RealityConfig? {
        guard security == "reality",
              let reality = JSONDocument.object(streamSettings)?["realitySettings"] as? [String: Any]
        else { return nil }
        let inner = reality["settings"] as? [String: Any]
        let target = (reality["target"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (reality["dest"] as? String) ?? ""
        return RealityConfig(
            target: target,
            serverNames: reality["serverNames"] as? [String] ?? [],
            shortIds: reality["shortIds"] as? [String] ?? [],
            privateKey: reality["privateKey"] as? String ?? "",
            publicKey: inner?["publicKey"] as? String ?? "",
            fingerprint: (inner?["fingerprint"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "chrome"
        )
    }

    /// The app edits VLESS + REALITY inbounds; every other protocol is read-only here.
    public var isEditableReality: Bool { protocolName == "vless" && security == "reality" }

    /// `VLESS · Reality · TCP`
    public var summary: String {
        var parts = [protocolName.uppercased()]
        if security != "none" { parts.append(security == "reality" ? "Reality" : security.uppercased()) }
        if !network.isEmpty { parts.append(network.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// A VLESS Reality inbound over TCP gets the Vision flow on its clients (unless the inbound disables flows).
    public var wantsVisionFlow: Bool {
        protocolName == "vless" && security == "reality" && (network.isEmpty || network == "tcp") && !disableFlow
    }
}

/// An inbound as `GET /panel/api/inbounds/get/:id` sent it: the typed view and the raw JSON,
/// kept so an edit changes only the fields the app owns and repeats the rest.
public struct InboundDetail: Equatable, Sendable {
    public var inbound: Inbound
    var raw: Data

    public init(inbound: Inbound, raw: Data = Data()) {
        self.inbound = inbound
        self.raw = raw
    }
}

public struct RealityKeyPair: Decodable, Equatable, Sendable {
    public var privateKey: String
    public var publicKey: String

    public init(privateKey: String, publicKey: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }
}

/// What the add and edit forms edit for a VLESS Reality inbound.
public struct RealityInboundDraft: Equatable, Sendable {
    public static let visionFlow = "xtls-rprx-vision"
    public static let defaultFingerprint = "chrome"

    /// nil for a new inbound.
    public var inboundId: Int?
    public var remark: String
    public var port: Int
    /// `host:port` of the site REALITY borrows its handshake from.
    public var target: String
    public var serverNamesText: String
    public var shortIdsText: String
    /// Blank on a new inbound: the panel's x25519 route makes a pair when the inbound is saved.
    public var privateKey: String
    public var publicKey: String
    public var fingerprint: String
    /// Clients get `flow: xtls-rprx-vision`. Off sets the inbound's `disableFlow`.
    public var useVisionFlow: Bool

    public init(
        inboundId: Int? = nil, remark: String = "VLESS Reality", port: Int = 443,
        target: String = "www.microsoft.com:443", serverNamesText: String = "www.microsoft.com",
        shortIdsText: String = "", privateKey: String = "", publicKey: String = "",
        fingerprint: String = RealityInboundDraft.defaultFingerprint, useVisionFlow: Bool = true
    ) {
        self.inboundId = inboundId; self.remark = remark; self.port = port; self.target = target
        self.serverNamesText = serverNamesText; self.shortIdsText = shortIdsText
        self.privateKey = privateKey; self.publicKey = publicKey; self.fingerprint = fingerprint
        self.useVisionFlow = useVisionFlow
    }

    public init(editing inbound: Inbound) {
        let reality = inbound.reality ?? RealityConfig()
        self.init(
            inboundId: inbound.id, remark: inbound.remark, port: inbound.port, target: reality.target,
            serverNamesText: reality.serverNames.joined(separator: ", "),
            shortIdsText: reality.shortIds.joined(separator: ", "),
            privateKey: reality.privateKey, publicKey: reality.publicKey, fingerprint: reality.fingerprint,
            useVisionFlow: !inbound.disableFlow
        )
    }

    /// A new draft with two random short ids (8 hex digits each).
    public static func newDraft() -> RealityInboundDraft {
        RealityInboundDraft(shortIdsText: [randomShortId(), randomShortId()].joined(separator: ", "))
    }

    public static func randomShortId() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    public var isNew: Bool { inboundId == nil }
    public var serverNames: [String] { Self.list(serverNamesText) }
    public var shortIds: [String] { Self.list(shortIdsText) }

    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let keyPattern = "^[A-Za-z0-9_-]{43}$"
    private static let hostPattern = "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"

    /// A message when the draft cannot be sent; nil when it can.
    public var validationError: String? {
        if remark.isBlank { return "Give the inbound a name." }
        if !(1...65_535).contains(port) { return "The port must be between 1 and 65535." }
        let parts = target.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]).range(of: Self.hostPattern, options: .regularExpression) != nil,
              let targetPort = Int(parts[1]), (1...65_535).contains(targetPort)
        else { return "The target must look like www.example.com:443." }
        if serverNames.isEmpty { return "Add at least one server name (SNI)." }
        for name in serverNames where name.replacingOccurrences(of: "*.", with: "").range(of: Self.hostPattern, options: .regularExpression) == nil {
            return "\"\(name)\" is not a valid server name."
        }
        if shortIds.isEmpty { return "Add at least one short id." }
        for id in shortIds {
            if id.count > 16 || id.count % 2 != 0 || id.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) == nil {
                return "A short id is 2 to 16 hexadecimal digits, in pairs. \"\(id)\" is not."
            }
        }
        if !privateKey.isBlank, privateKey.range(of: Self.keyPattern, options: .regularExpression) == nil {
            return "The private key must be 43 characters (base64url)."
        }
        if !publicKey.isBlank, publicKey.range(of: Self.keyPattern, options: .regularExpression) == nil {
            return "The public key must be 43 characters (base64url)."
        }
        if privateKey.isBlank != publicKey.isBlank && !isNew {
            return "Keep or replace the private and public keys together."
        }
        return nil
    }

    /// The JSON body of `POST /panel/api/inbounds/add` or `/update/:id`.
    ///
    /// `existing` is the raw `GET /inbounds/get/:id` answer when editing. The body is that answer with
    /// the fields the form owns replaced, so every other field of the inbound (sniffing, sockopt, the
    /// network settings, the stored client list) goes back as it was. `settings`, `streamSettings` and
    /// `sniffing` are sent as JSON strings, as the panel's own pages do.
    func makeBody(existing: Data?) throws -> Data {
        if let problem = validationError { throw PanelError.invalidRequest(problem) }
        var root: [String: Any]
        if let existing {
            guard let object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else { throw PanelError.decoding }
            root = object
            for key in ["id", "clientStats", "fallbackParent", "userId"] { root[key] = nil }
        } else {
            root = [
                "enable": true, "up": 0, "down": 0, "total": 0, "expiryTime": 0, "listen": "", "tag": "",
                "trafficReset": "never", "trafficResetDay": 1, "lastTrafficResetTime": 0,
                "subSortIndex": 1, "excludeFromSub": false, "shareAddrStrategy": "node", "shareAddr": "",
            ]
        }
        root["protocol"] = "vless"
        root["remark"] = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        root["port"] = port
        root["disableFlow"] = !useVisionFlow

        // settings: keep the stored document; a new inbound starts without clients.
        var settings = Self.document(root["settings"]) ?? [:]
        if settings["clients"] == nil { settings["clients"] = [Any]() }
        if settings["decryption"] == nil { settings["decryption"] = "none" }
        if settings["encryption"] == nil { settings["encryption"] = "none" }
        if settings["fallbacks"] == nil { settings["fallbacks"] = [Any]() }
        root["settings"] = JSONDocument.string(settings)

        var stream = Self.document(root["streamSettings"]) ?? [:]
        if stream["network"] == nil {
            stream["network"] = "tcp"
            stream["tcpSettings"] = ["acceptProxyProtocol": false, "header": ["type": "none"]] as [String: Any]
        }
        stream["security"] = "reality"
        var reality = (stream["realitySettings"] as? [String: Any]) ?? [
            "show": false, "xver": 0, "minClientVer": "", "maxClientVer": "", "maxTimediff": 0, "mldsa65Seed": "",
        ]
        reality["dest"] = nil
        reality["target"] = target.trimmingCharacters(in: .whitespacesAndNewlines)
        reality["serverNames"] = serverNames
        reality["shortIds"] = shortIds
        if !privateKey.isBlank { reality["privateKey"] = privateKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        var inner = (reality["settings"] as? [String: Any]) ?? ["serverName": "", "spiderX": "/", "mldsa65Verify": ""]
        if !publicKey.isBlank { inner["publicKey"] = publicKey.trimmingCharacters(in: .whitespacesAndNewlines) }
        inner["fingerprint"] = fingerprint.isBlank ? Self.defaultFingerprint : fingerprint
        reality["settings"] = inner
        stream["realitySettings"] = reality
        root["streamSettings"] = JSONDocument.string(stream)

        var sniffing = Self.document(root["sniffing"]) ?? [
            "enabled": true, "destOverride": ["http", "tls", "quic", "fakedns"],
            "metadataOnly": false, "routeOnly": false, "ipsExcluded": [Any](), "domainsExcluded": [Any](),
        ]
        if sniffing["enabled"] == nil { sniffing["enabled"] = true }
        root["sniffing"] = JSONDocument.string(sniffing)

        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// A field that holds a JSON document, as a string or as an embedded object.
    private static func document(_ value: Any?) -> [String: Any]? {
        if let text = value as? String { return JSONDocument.object(text) }
        return value as? [String: Any]
    }
}
