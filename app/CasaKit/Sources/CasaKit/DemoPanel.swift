import Foundation

/// A fictional panel for the "Try the demo" button and for App Review: it answers every `PanelAPI`
/// call from sample data held in memory, offline. Writes change that memory only; nothing leaves the device.
/// Hosts are `example.com` and addresses are in `203.0.113.0/24` (RFC 5737 documentation ranges).
public actor DemoPanel: PanelAPI {
    public static let serverName = "Demo server"
    public static let host = "demo.example.com"
    public static let subscriptionBaseURL = "https://demo.example.com:2096/sub/"
    public static let realityPublicKey = "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A"
    public static let realityPrivateKey = "yK3tNn8vBq1ZcR6eHs0LxWp4UoJm2AaD9gFiTb7QeXw"

    private var status: ServerStatus
    private var tick = 0
    private var inboundList: [Inbound]
    private var clientList: [DemoClient]
    private var online: Set<String>
    private var nextInboundId = 3
    private let now: () -> Date

    struct DemoClient {
        var detail: ClientDetail
        var up: Int64
        var down: Int64
        var lastOnline: Int64
    }

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let seed = DemoData.make(now: now())
        status = seed.status
        inboundList = seed.inbounds
        clientList = seed.clients
        online = seed.online
    }

    // MARK: Status and Xray

    public func serverStatus() async throws -> ServerStatus {
        tick += 1
        var s = status
        // Small, deterministic movement so the numbers look alive on refresh.
        let wave = Double((tick * 7) % 11) - 5
        s.cpu = max(2, min(97, s.cpu + wave))
        s.netUp = UInt64(max(0, Int(s.netUp) + Int(wave) * 4_096))
        s.netDown = UInt64(max(0, Int(s.netDown) + Int(wave) * 16_384))
        s.uptime += UInt64(tick) * 30
        if s.xray.state != .running { s.cpu = 3; s.netUp = 0; s.netDown = 0 }
        return s
    }

    public func restartXray() async throws {
        status.xray = ServerStatus.Xray(state: .running, errorMsg: "", version: status.xray.version)
    }

    public func stopXray() async throws {
        status.xray = ServerStatus.Xray(state: .stop, errorMsg: "", version: status.xray.version)
    }

    public func xrayLog(count: Int, filter: String) async throws -> [XrayLogEntry] {
        let entries = DemoData.accessLog(now: now(), emails: clientList.map(\.detail.email))
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = needle.isEmpty ? entries : entries.filter { $0.line.lowercased().contains(needle) }
        return Array(filtered.suffix(max(1, count)))
    }

    public func panelLog(count: Int, level: String) async throws -> [String] {
        Array(DemoData.panelLog(now: now()).suffix(max(1, count)))
    }

    // MARK: Inbounds

    public func inbounds() async throws -> [Inbound] {
        inboundList.map(refreshed)
    }

    public func inbound(id: Int) async throws -> InboundDetail {
        guard let inbound = inboundList.first(where: { $0.id == id }) else { throw PanelError.api("Inbound not found.") }
        let current = refreshed(inbound)
        return InboundDetail(inbound: current, raw: DemoData.rawJSON(of: current))
    }

    public func setInboundEnabled(id: Int, enabled: Bool) async throws {
        try mutateInbound(id) { $0.enable = enabled }
    }

    public func resetInboundTraffic(id: Int) async throws {
        try mutateInbound(id) { $0.up = 0; $0.down = 0 }
        for index in clientList.indices where clientList[index].detail.inboundIds.contains(id) {
            clientList[index].up = 0
            clientList[index].down = 0
        }
    }

    public func saveInbound(_ draft: RealityInboundDraft) async throws {
        var draft = draft
        if draft.privateKey.isBlank {
            let pair = try await newRealityKeyPair()
            draft.privateKey = pair.privateKey
            draft.publicKey = pair.publicKey
        }
        if let id = draft.inboundId {
            guard let index = inboundList.firstIndex(where: { $0.id == id }) else { throw PanelError.api("Inbound not found.") }
            let body = try draft.makeBody(existing: DemoData.rawJSON(of: inboundList[index]))
            inboundList[index] = try DemoData.inbound(fromBody: body, id: id)
        } else {
            if inboundList.contains(where: { $0.port == draft.port }) { throw PanelError.api("Port \(draft.port) is already used by another inbound.") }
            let body = try draft.makeBody(existing: nil)
            inboundList.append(try DemoData.inbound(fromBody: body, id: nextInboundId))
            nextInboundId += 1
        }
    }

    public func deleteInbound(id: Int) async throws {
        guard inboundList.contains(where: { $0.id == id }) else { throw PanelError.api("Inbound not found.") }
        inboundList.removeAll { $0.id == id }
        for index in clientList.indices { clientList[index].detail.inboundIds.removeAll { $0 == id } }
        clientList.removeAll { $0.detail.inboundIds.isEmpty }
    }

    public func newRealityKeyPair() async throws -> RealityKeyPair {
        func key() -> String {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            var generator = SystemRandomNumberGenerator()
            return String((0..<43).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
        }
        return RealityKeyPair(privateKey: key(), publicKey: key())
    }

    // MARK: Clients

    public func clients() async throws -> ClientsSnapshot {
        ClientsSnapshot(clients: clientList.map(vpnClient), online: online.intersection(clientList.map(\.detail.email)))
    }

    public func client(email: String) async throws -> ClientDetail {
        guard let found = clientList.first(where: { $0.detail.email == email }) else { throw PanelError.api("Client not found.") }
        var detail = found.detail
        detail.usedBytes = found.up + found.down
        return detail
    }

    public func saveClient(_ draft: ClientDraft) async throws {
        if let error = draft.validationError { throw PanelError.invalidRequest(error) }
        let name = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let original = draft.originalEmail {
            guard let index = clientList.firstIndex(where: { $0.detail.email == original }) else { throw PanelError.api("Client not found.") }
            var detail = clientList[index].detail
            detail.enable = draft.enable
            detail.totalBytes = draft.totalBytes
            detail.expiryTime = draft.expiry.milliseconds
            detail.limitIp = max(0, draft.limitIp)
            detail.comment = draft.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !draft.subId.isBlank { detail.subId = draft.subId.trimmingCharacters(in: .whitespacesAndNewlines) }
            clientList[index].detail = detail
        } else {
            if clientList.contains(where: { $0.detail.email.caseInsensitiveCompare(name) == .orderedSame }) {
                throw PanelError.api("A client with this name already exists.")
            }
            let detail = ClientDetail(
                email: name, uuid: UUID().uuidString.lowercased(),
                subId: draft.subId.isBlank ? ClientDraft.randomSubId() : draft.subId,
                enable: draft.enable, totalBytes: draft.totalBytes, expiryTime: draft.expiry.milliseconds,
                limitIp: max(0, draft.limitIp), comment: draft.comment, flow: draft.flow, inboundIds: draft.inboundIds
            )
            clientList.append(DemoClient(detail: detail, up: 0, down: 0, lastOnline: 0))
        }
    }

    public func setClientEnabled(email: String, enabled: Bool) async throws {
        try mutateClient(email) { $0.detail.enable = enabled }
        if !enabled { online.remove(email) }
    }

    public func resetClientTraffic(email: String) async throws {
        try mutateClient(email) { $0.up = 0; $0.down = 0 }
    }

    public func deleteClient(email: String) async throws {
        guard clientList.contains(where: { $0.detail.email == email }) else { throw PanelError.api("Client not found.") }
        clientList.removeAll { $0.detail.email == email }
        online.remove(email)
    }

    public func clientLinks(email: String) async throws -> [String] {
        guard let found = clientList.first(where: { $0.detail.email == email }) else { throw PanelError.api("Client not found.") }
        return inboundList.filter { found.detail.inboundIds.contains($0.id) }.map { DemoData.link(for: found.detail, in: $0) }
    }

    public func subscriptionBase() async throws -> String? { Self.subscriptionBaseURL }

    // MARK: State

    private func mutateInbound(_ id: Int, _ change: (inout Inbound) -> Void) throws {
        guard let index = inboundList.firstIndex(where: { $0.id == id }) else { throw PanelError.api("Inbound not found.") }
        change(&inboundList[index])
    }

    private func mutateClient(_ email: String, _ change: (inout DemoClient) -> Void) throws {
        guard let index = clientList.firstIndex(where: { $0.detail.email == email }) else { throw PanelError.api("Client not found.") }
        change(&clientList[index])
    }

    private func vpnClient(_ item: DemoClient) -> VPNClient {
        let detail = item.detail
        return VPNClient(
            email: detail.email, subId: detail.subId, enable: detail.enable, totalBytes: detail.totalBytes,
            expiryTime: detail.expiryTime, comment: detail.comment, group: detail.group,
            traffic: ClientTraffic(
                up: item.up, down: item.down, total: detail.totalBytes, lastOnline: item.lastOnline,
                email: detail.email, inboundId: detail.inboundIds.first ?? 0, enable: detail.enable
            ),
            inboundIds: detail.inboundIds, limitIp: detail.limitIp
        )
    }

    /// An inbound with traffic and client rows computed from its clients.
    private func refreshed(_ inbound: Inbound) -> Inbound {
        var copy = inbound
        let members = clientList.filter { $0.detail.inboundIds.contains(inbound.id) }
        copy.clientStats = members.map {
            ClientTraffic(up: $0.up, down: $0.down, total: $0.detail.totalBytes, lastOnline: $0.lastOnline,
                          email: $0.detail.email, inboundId: inbound.id, enable: $0.detail.enable)
        }
        let used = members.reduce((up: Int64(0), down: Int64(0))) { ($0.up + $1.up, $0.down + $1.down) }
        copy.up = used.up
        copy.down = used.down
        var settings = JSONDocument.object(inbound.settings) ?? [:]
        settings["clients"] = members.map { ["email": $0.detail.email, "enable": $0.detail.enable] as [String: Any] }
        copy.settings = JSONDocument.string(settings)
        return copy
    }
}
