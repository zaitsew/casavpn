import Foundation

// Models for the 3x-ui panel API, shaped like the structs of v3.10.2:
//   internal/web/service/server.go        Status          -> GET  /panel/api/server/status
//   internal/web/service/client_paging.go ClientPageResponse, ClientSlim
//                                                         -> GET  /panel/api/clients/list/paged
//   internal/xray/client_traffic.go       ClientTraffic (the `traffic` of a ClientSlim)
//   internal/database/model/model.go      ClientRecord    -> GET  /panel/api/clients/get/:email
// Every field is decoded leniently: the panel adds fields in each release.

/// `{"success": bool, "msg": string, "obj": ...}`, the wrapper of every panel answer.
struct PanelEnvelope<T: Decodable>: Decodable {
    var success: Bool
    var msg: String?
    var obj: T?

    private enum CodingKeys: String, CodingKey { case success, msg, obj }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? false
        msg = try c.decodeIfPresent(String.self, forKey: .msg)
        obj = try? c.decodeIfPresent(T.self, forKey: .obj)
    }
}

public struct ServerStatus: Decodable, Equatable, Sendable {
    public struct Usage: Decodable, Equatable, Sendable {
        public var current: UInt64
        public var total: UInt64

        public init(current: UInt64 = 0, total: UInt64 = 0) {
            self.current = current
            self.total = total
        }

        public var fraction: Double { total == 0 ? 0 : min(1, Double(current) / Double(total)) }

        private enum CodingKeys: String, CodingKey { case current, total }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            current = try c.decodeIfPresent(UInt64.self, forKey: .current) ?? 0
            total = try c.decodeIfPresent(UInt64.self, forKey: .total) ?? 0
        }
    }

    public enum XrayState: String, Decodable, Sendable {
        case running, stop, error, unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = XrayState(rawValue: raw) ?? .unknown
        }
    }

    public struct Xray: Decodable, Equatable, Sendable {
        public var state: XrayState
        public var errorMsg: String
        public var version: String

        public init(state: XrayState = .unknown, errorMsg: String = "", version: String = "") {
            self.state = state
            self.errorMsg = errorMsg
            self.version = version
        }

        private enum CodingKeys: String, CodingKey { case state, errorMsg, version }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decodeIfPresent(XrayState.self, forKey: .state) ?? .unknown
            errorMsg = try c.decodeIfPresent(String.self, forKey: .errorMsg) ?? ""
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        }
    }

    /// CPU use in percent, 0 to 100.
    public var cpu: Double
    public var cpuCores: Int
    public var mem: Usage
    public var swap: Usage
    public var disk: Usage
    public var xray: Xray
    /// Host uptime in seconds.
    public var uptime: UInt64
    /// 1, 5 and 15 minute load averages.
    public var loads: [Double]
    public var tcpCount: Int
    public var panelVersion: String
    public var publicIPv4: String?
    public var publicIPv6: String?

    private enum CodingKeys: String, CodingKey {
        case cpu, cpuCores, mem, swap, disk, xray, uptime, loads, tcpCount, panelVersion, publicIP
    }
    private enum IPKeys: String, CodingKey { case ipv4, ipv6 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = try c.decodeIfPresent(Double.self, forKey: .cpu) ?? 0
        cpuCores = try c.decodeIfPresent(Int.self, forKey: .cpuCores) ?? 0
        mem = try c.decodeIfPresent(Usage.self, forKey: .mem) ?? Usage()
        swap = try c.decodeIfPresent(Usage.self, forKey: .swap) ?? Usage()
        disk = try c.decodeIfPresent(Usage.self, forKey: .disk) ?? Usage()
        xray = try c.decodeIfPresent(Xray.self, forKey: .xray) ?? Xray()
        uptime = try c.decodeIfPresent(UInt64.self, forKey: .uptime) ?? 0
        loads = try c.decodeIfPresent([Double].self, forKey: .loads) ?? []
        tcpCount = try c.decodeIfPresent(Int.self, forKey: .tcpCount) ?? 0
        panelVersion = try c.decodeIfPresent(String.self, forKey: .panelVersion) ?? ""
        if let ip = try? c.nestedContainer(keyedBy: IPKeys.self, forKey: .publicIP) {
            publicIPv4 = (try? ip.decodeIfPresent(String.self, forKey: .ipv4)).flatMap { $0.isEmpty ? nil : $0 }
            publicIPv6 = (try? ip.decodeIfPresent(String.self, forKey: .ipv6)).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

/// Usage counters the panel keeps per client (`xray.ClientTraffic`).
public struct ClientTraffic: Decodable, Equatable, Sendable {
    public var up: Int64
    public var down: Int64
    /// The traffic limit in bytes; 0 means unlimited.
    public var total: Int64
    /// Unix milliseconds of the last connection; 0 when never.
    public var lastOnline: Int64

    public init(up: Int64 = 0, down: Int64 = 0, total: Int64 = 0, lastOnline: Int64 = 0) {
        self.up = up
        self.down = down
        self.total = total
        self.lastOnline = lastOnline
    }

    private enum CodingKeys: String, CodingKey { case up, down, total, lastOnline }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        up = try c.decodeIfPresent(Int64.self, forKey: .up) ?? 0
        down = try c.decodeIfPresent(Int64.self, forKey: .down) ?? 0
        total = try c.decodeIfPresent(Int64.self, forKey: .total) ?? 0
        lastOnline = try c.decodeIfPresent(Int64.self, forKey: .lastOnline) ?? 0
    }
}

/// One VPN client as the Clients tab shows it (`service.ClientSlim`).
public struct VPNClient: Decodable, Equatable, Identifiable, Sendable {
    public var email: String
    public var subId: String
    public var enable: Bool
    /// The traffic limit in bytes (the field is called `totalGB` but holds bytes); 0 means unlimited.
    public var totalBytes: Int64
    /// Unix milliseconds. 0 means never; a negative value means "this many milliseconds
    /// after the first connection".
    public var expiryTime: Int64
    public var comment: String
    public var group: String
    public var traffic: ClientTraffic?

    public var id: String { email }

    public init(
        email: String, subId: String = "", enable: Bool = true, totalBytes: Int64 = 0,
        expiryTime: Int64 = 0, comment: String = "", group: String = "", traffic: ClientTraffic? = nil
    ) {
        self.email = email
        self.subId = subId
        self.enable = enable
        self.totalBytes = totalBytes
        self.expiryTime = expiryTime
        self.comment = comment
        self.group = group
        self.traffic = traffic
    }

    public var usedBytes: Int64 { (traffic?.up ?? 0) + (traffic?.down ?? 0) }

    /// The limit in bytes, or nil when unlimited.
    public var limitBytes: Int64? {
        let limit = totalBytes > 0 ? totalBytes : (traffic?.total ?? 0)
        return limit > 0 ? limit : nil
    }

    private enum CodingKeys: String, CodingKey {
        case email, subId, enable, totalGB, expiryTime, comment, group, traffic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        email = try c.decode(String.self, forKey: .email)
        subId = try c.decodeIfPresent(String.self, forKey: .subId) ?? ""
        enable = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? true
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalGB) ?? 0
        expiryTime = try c.decodeIfPresent(Int64.self, forKey: .expiryTime) ?? 0
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        traffic = try c.decodeIfPresent(ClientTraffic.self, forKey: .traffic)
    }
}

/// `service.ClientPageResponse`: one page of clients and the panel-wide summary.
struct ClientPage: Decodable {
    struct Summary: Decodable {
        var online: [String]

        private enum CodingKeys: String, CodingKey { case online }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Go encodes a nil slice as null.
            online = try c.decodeIfPresent([String].self, forKey: .online) ?? []
        }
    }

    var items: [VPNClient]
    var total: Int
    var summary: Summary

    private enum CodingKeys: String, CodingKey { case items, total, summary }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([VPNClient].self, forKey: .items) ?? []
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary) ?? Summary(online: [])
    }
}

extension ClientPage.Summary {
    init(online: [String]) { self.online = online }
}

public struct ClientsSnapshot: Equatable, Sendable {
    public var clients: [VPNClient]
    /// Emails of the clients with an open connection now.
    public var online: Set<String>
}

/// `GET /panel/api/clients/get/:email` -> `{"client": <ClientRecord>, "inboundIds": [...], ...}`.
/// Only the fields that `POST /panel/api/clients/update/:email` overwrites are kept.
struct ClientRecordPayload: Decodable {
    struct Record: Decodable {
        var email: String
        var subId: String
        var security: String
        var flow: String
        var limitIp: Int
        var limitHwid: Int
        var totalGB: Int64
        var expiryTime: Int64
        var enable: Bool
        var tgId: Int64
        var group: String
        var comment: String
        var reset: Int
        var resetDay: Int
        var resetWeekday: Int
        var resetMax: Int
        var trafficReset: String
        var trafficResetDay: Int

        private enum CodingKeys: String, CodingKey {
            case email, subId, security, flow, limitIp, limitHwid, totalGB, expiryTime, enable, tgId
            case group, comment, reset, resetDay, resetWeekday, resetMax, trafficReset, trafficResetDay
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            email = try c.decode(String.self, forKey: .email)
            subId = try c.decodeIfPresent(String.self, forKey: .subId) ?? ""
            security = try c.decodeIfPresent(String.self, forKey: .security) ?? ""
            flow = try c.decodeIfPresent(String.self, forKey: .flow) ?? ""
            limitIp = try c.decodeIfPresent(Int.self, forKey: .limitIp) ?? 0
            limitHwid = try c.decodeIfPresent(Int.self, forKey: .limitHwid) ?? 0
            totalGB = try c.decodeIfPresent(Int64.self, forKey: .totalGB) ?? 0
            expiryTime = try c.decodeIfPresent(Int64.self, forKey: .expiryTime) ?? 0
            enable = try c.decodeIfPresent(Bool.self, forKey: .enable) ?? true
            tgId = try c.decodeIfPresent(Int64.self, forKey: .tgId) ?? 0
            group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
            comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
            reset = try c.decodeIfPresent(Int.self, forKey: .reset) ?? 0
            resetDay = try c.decodeIfPresent(Int.self, forKey: .resetDay) ?? 0
            resetWeekday = try c.decodeIfPresent(Int.self, forKey: .resetWeekday) ?? 0
            resetMax = try c.decodeIfPresent(Int.self, forKey: .resetMax) ?? 0
            trafficReset = try c.decodeIfPresent(String.self, forKey: .trafficReset) ?? ""
            trafficResetDay = try c.decodeIfPresent(Int.self, forKey: .trafficResetDay) ?? 0
        }
    }

    var client: Record
}

/// The body of `POST /panel/api/clients/update/:email` (a `model.Client`).
///
/// The panel overwrites every field it receives, so the body repeats the current value
/// of each one and changes only `enable`. `id`, `password`, `auth` and `secret` are left
/// out on purpose: the panel keeps the stored credentials when they are empty
/// (service.ClientService.Update). `keepAlive` is also omitted ("omit to keep the stored value").
struct ClientUpdateBody: Encodable, Equatable {
    var email: String
    var subId: String
    var security: String
    var flow: String
    var limitIp: Int
    var limitHwid: Int
    var totalGB: Int64
    var expiryTime: Int64
    var enable: Bool
    var tgId: Int64
    var group: String
    var comment: String
    var reset: Int
    var resetDay: Int
    var resetWeekday: Int
    var resetMax: Int
    var trafficReset: String
    var trafficResetDay: Int

    init(from record: ClientRecordPayload.Record, enable: Bool) {
        email = record.email
        subId = record.subId
        security = record.security
        flow = record.flow
        limitIp = record.limitIp
        limitHwid = record.limitHwid
        totalGB = record.totalGB
        expiryTime = record.expiryTime
        self.enable = enable
        tgId = record.tgId
        group = record.group
        comment = record.comment
        reset = record.reset
        resetDay = record.resetDay
        resetWeekday = record.resetWeekday
        resetMax = record.resetMax
        trafficReset = record.trafficReset
        trafficResetDay = record.trafficResetDay
    }
}
