import Foundation

/// The 3x-ui v3.10.2 API as the app uses it. The panel URL already carries the base path;
/// every route lives under `<panel URL>/panel/api/`. A token goes in `Authorization: Bearer`
/// (internal/web/controller/api.go, checkAPIAuth), which also skips the CSRF check. A session
/// (the sign-in fallback) sends its cookie, `X-CSRF-Token` and `X-Requested-With`.
public struct PanelClient: PanelAPI {
    public static let pageSize = 200
    /// A safety cap, not a limit anyone should meet: 1,000 pages of 200 is 200,000 clients.
    public static let defaultMaxPages = 1_000
    /// The name of the panel's session cookie (`sessions.Sessions("3x-ui", ...)`).
    public static let sessionCookieName = "3x-ui"

    public let baseURL: URL
    private let credential: PanelCredential
    private let headers: [CustomHeader]
    private let transport: any HTTPTransport
    private let maxPages: Int

    public init(
        baseURL: URL,
        credential: PanelCredential,
        headers: [CustomHeader] = [],
        transport: any HTTPTransport = URLSessionTransport(),
        maxPages: Int = PanelClient.defaultMaxPages
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.headers = headers
        self.transport = transport
        self.maxPages = maxPages
    }

    public init(
        baseURL: URL,
        token: String,
        transport: any HTTPTransport = URLSessionTransport(),
        maxPages: Int = PanelClient.defaultMaxPages
    ) {
        self.init(baseURL: baseURL, credential: .bearer(token), transport: transport, maxPages: maxPages)
    }

    /// A client for the saved settings; nil when they hold no valid URL or credential.
    public init?(settings: ConnectionSettings, transport: any HTTPTransport = URLSessionTransport()) {
        guard let base = settings.panelBase, let credential = settings.panelCredential else { return nil }
        self.init(baseURL: base, credential: credential, headers: settings.panelHeaders, transport: transport)
    }

    // MARK: Requests

    public func makeRequest(
        method: String = "GET",
        route: [String],
        query: [URLQueryItem] = [],
        body: Data? = nil,
        form: [(String, String)]? = nil
    ) throws -> URLRequest {
        let path = "/panel/api/" + route.map(encodePathSegment).joined(separator: "/")
        return try PanelRequest.make(
            base: baseURL, path: path, method: method, query: query, credential: credential,
            headers: headers, json: body, form: form
        )
    }

    private var sessionMode: Bool {
        if case .session = credential { return true }
        return false
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try await PanelRequest.perform(request, transport: transport, sessionMode: sessionMode)
    }

    /// Sends the request and unwraps `{"success", "msg", "obj"}`.
    private func object<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let data = try await perform(request)
        let envelope: PanelEnvelope<T>
        do { envelope = try JSONDecoder().decode(PanelEnvelope<T>.self, from: data) } catch { throw PanelError.decoding }
        guard envelope.success else { throw PanelError.api(envelope.msg ?? "") }
        guard let obj = envelope.obj else { throw PanelError.decoding }
        return obj
    }

    /// Like `object`, for lists the panel answers as `null` when empty.
    private func optionalObject<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T? {
        let data = try await perform(request)
        let envelope: PanelEnvelope<T>
        do { envelope = try JSONDecoder().decode(PanelEnvelope<T>.self, from: data) } catch { throw PanelError.decoding }
        guard envelope.success else { throw PanelError.api(envelope.msg ?? "") }
        return envelope.obj
    }

    /// The `obj` of an answer as raw JSON, so an edit can send back what it did not change.
    private func rawObject(_ request: URLRequest) async throws -> Data {
        let data = try await perform(request)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw PanelError.decoding }
        guard (root["success"] as? Bool) == true else { throw PanelError.api(root["msg"] as? String ?? "") }
        guard let obj = root["obj"], !(obj is NSNull) else { throw PanelError.decoding }
        return try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
    }

    /// Sends a request whose answer carries no object we need (`obj` is null or `{"nodePending": true}`).
    private func command(_ request: URLRequest) async throws {
        let data = try await perform(request)
        let envelope: PanelEnvelope<AnyDecodable>
        do { envelope = try JSONDecoder().decode(PanelEnvelope<AnyDecodable>.self, from: data) } catch { throw PanelError.decoding }
        guard envelope.success else { throw PanelError.api(envelope.msg ?? "") }
    }

    private func jsonBody(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: Status and Xray

    /// `GET /panel/api/server/status`. Allowed for admin and monitor tokens.
    public func serverStatus() async throws -> ServerStatus {
        try await object(ServerStatus.self, makeRequest(route: ["server", "status"]))
    }

    /// `POST /panel/api/server/restartXrayService`.
    public func restartXray() async throws {
        try await command(makeRequest(method: "POST", route: ["server", "restartXrayService"]))
    }

    /// `POST /panel/api/server/stopXrayService`.
    public func stopXray() async throws {
        try await command(makeRequest(method: "POST", route: ["server", "stopXrayService"]))
    }

    /// `POST /panel/api/server/xraylogs/:count` (form `filter`, `showDirect`, `showBlocked`, `showProxy`).
    public func xrayLog(count: Int, filter: String) async throws -> [XrayLogEntry] {
        let request = try makeRequest(
            method: "POST", route: ["server", "xraylogs", String(max(1, min(count, 1000)))],
            form: [("filter", filter), ("showDirect", "true"), ("showBlocked", "true"), ("showProxy", "true")]
        )
        return try await optionalObject([XrayLogEntry].self, request) ?? []
    }

    /// `POST /panel/api/server/logs/:count` (form `level`, `syslog`).
    public func panelLog(count: Int, level: String) async throws -> [String] {
        let request = try makeRequest(
            method: "POST", route: ["server", "logs", String(max(1, min(count, 1000)))],
            form: [("level", level), ("syslog", "false")]
        )
        return try await optionalObject([String].self, request) ?? []
    }

    // MARK: Inbounds

    /// `GET /panel/api/inbounds/list/slim`.
    public func inbounds() async throws -> [Inbound] {
        try await optionalObject([Inbound].self, makeRequest(route: ["inbounds", "list", "slim"])) ?? []
    }

    /// `GET /panel/api/inbounds/get/:id`.
    public func inbound(id: Int) async throws -> InboundDetail {
        let raw = try await rawObject(makeRequest(route: ["inbounds", "get", String(id)]))
        guard let inbound = try? JSONDecoder().decode(Inbound.self, from: raw) else { throw PanelError.decoding }
        return InboundDetail(inbound: inbound, raw: raw)
    }

    private struct EnableBody: Encodable { var enable: Bool }

    /// `POST /panel/api/inbounds/setEnable/:id`.
    public func setInboundEnabled(id: Int, enabled: Bool) async throws {
        try await command(makeRequest(
            method: "POST", route: ["inbounds", "setEnable", String(id)], body: jsonBody(EnableBody(enable: enabled))
        ))
    }

    /// `POST /panel/api/inbounds/:id/resetTraffic`.
    public func resetInboundTraffic(id: Int) async throws {
        try await command(makeRequest(method: "POST", route: ["inbounds", String(id), "resetTraffic"]))
    }

    /// New inbound: `POST /panel/api/inbounds/add`. Existing: `GET inbounds/get/:id`, then
    /// `POST inbounds/update/:id` with that answer and the form's fields replaced.
    public func saveInbound(_ draft: RealityInboundDraft) async throws {
        var draft = draft
        if let id = draft.inboundId {
            let current = try await inbound(id: id)
            let body = try draft.makeBody(existing: current.raw)
            try await command(makeRequest(method: "POST", route: ["inbounds", "update", String(id)], body: body))
        } else {
            if draft.privateKey.isBlank {
                let pair = try await newRealityKeyPair()
                draft.privateKey = pair.privateKey
                draft.publicKey = pair.publicKey
            }
            try await command(makeRequest(method: "POST", route: ["inbounds", "add"], body: draft.makeBody(existing: nil)))
        }
    }

    /// `POST /panel/api/inbounds/del/:id`.
    public func deleteInbound(id: Int) async throws {
        try await command(makeRequest(method: "POST", route: ["inbounds", "del", String(id)]))
    }

    /// `GET /panel/api/server/getNewX25519Cert`.
    public func newRealityKeyPair() async throws -> RealityKeyPair {
        try await object(RealityKeyPair.self, makeRequest(route: ["server", "getNewX25519Cert"]))
    }

    // MARK: Clients

    /// `GET /panel/api/clients/list/paged?page=&pageSize=`, all pages, plus `POST clients/onlines`.
    /// The `online` emails also come with the list (`summary.online`); the two are merged.
    public func clients() async throws -> ClientsSnapshot {
        var items: [VPNClient] = []
        var online: [String] = []
        var complete = false
        for page in 1...max(1, maxPages) {
            let query = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: String(Self.pageSize)),
            ]
            let result = try await object(ClientPage.self, makeRequest(route: ["clients", "list", "paged"], query: query))
            items += result.items
            if page == 1 { online = result.summary.online }
            // The last page: the panel's own total is reached, or it has nothing more to give.
            if result.items.isEmpty || items.count >= result.total {
                complete = true
                break
            }
        }
        // Never hand back a silently partial list.
        guard complete else { throw PanelError.incompleteList }
        var onlineSet = Set(online)
        if let live = try? await optionalObject([String].self, makeRequest(method: "POST", route: ["clients", "onlines"])) {
            onlineSet.formUnion(live)
        }
        return ClientsSnapshot(clients: items, online: onlineSet)
    }

    /// `GET /panel/api/clients/get/:email`.
    public func client(email: String) async throws -> ClientDetail {
        let payload = try await object(ClientRecordPayload.self, makeRequest(route: ["clients", "get", email]))
        let record = payload.client
        return ClientDetail(
            email: record.email, uuid: record.uuid, subId: record.subId, enable: record.enable,
            totalBytes: record.totalGB, expiryTime: record.expiryTime, limitIp: record.limitIp,
            comment: record.comment, group: record.group, flow: record.flow,
            inboundIds: payload.inboundIds, usedBytes: payload.usedTraffic
        )
    }

    /// New client: `POST /panel/api/clients/add`. Existing: `GET clients/get/:email`, then
    /// `POST clients/update/:email` with the stored record and the form's fields replaced.
    public func saveClient(_ draft: ClientDraft) async throws {
        if let error = draft.validationError { throw PanelError.invalidRequest(error) }
        if let original = draft.originalEmail {
            let current = try await object(ClientRecordPayload.self, makeRequest(route: ["clients", "get", original]))
            let body = try jsonBody(ClientUpdateBody(from: current.client, applying: draft))
            try await command(makeRequest(method: "POST", route: ["clients", "update", original], body: body))
        } else {
            var draft = draft
            if draft.subId.isBlank { draft.subId = ClientDraft.randomSubId() }
            try await command(makeRequest(method: "POST", route: ["clients", "add"], body: jsonBody(ClientCreateBody(draft: draft))))
        }
    }

    /// Turns one client on or off: `GET /clients/get/:email` for the current record, then
    /// `POST /clients/update/:email` with the same record and `enable` changed.
    public func setClientEnabled(email: String, enabled: Bool) async throws {
        let current = try await object(ClientRecordPayload.self, makeRequest(route: ["clients", "get", email]))
        try await command(makeUpdateRequest(record: current.client, enable: enabled))
    }

    /// Builds the body that turns a client on or off. See `ClientUpdateBody`.
    func makeUpdateRequest(record: ClientRecordPayload.Record, enable: Bool) throws -> URLRequest {
        let body = try jsonBody(ClientUpdateBody(from: record, enable: enable))
        return try makeRequest(method: "POST", route: ["clients", "update", record.email], body: body)
    }

    /// `POST /panel/api/clients/resetTraffic/:email`.
    public func resetClientTraffic(email: String) async throws {
        try await command(makeRequest(method: "POST", route: ["clients", "resetTraffic", email]))
    }

    /// `POST /panel/api/clients/del/:email`.
    public func deleteClient(email: String) async throws {
        try await command(makeRequest(method: "POST", route: ["clients", "del", email]))
    }

    /// `GET /panel/api/clients/links/:email`.
    public func clientLinks(email: String) async throws -> [String] {
        try await optionalObject([String].self, makeRequest(route: ["clients", "links", email])) ?? []
    }

    private struct DefaultSettings: Decodable {
        var subURI: String?
        var subEnable: Bool?
    }

    /// `POST /panel/api/setting/defaultSettings` -> `subURI`.
    public func subscriptionBase() async throws -> String? {
        let settings = try await object(DefaultSettings.self, makeRequest(method: "POST", route: ["setting", "defaultSettings"]))
        guard let uri = settings.subURI, !uri.isBlank else { return nil }
        return uri
    }

    // MARK: API tokens

    /// `GET /panel/api/setting/apiTokens`.
    public func apiTokens() async throws -> [ApiTokenInfo] {
        try await optionalObject([ApiTokenInfo].self, makeRequest(route: ["setting", "apiTokens"])) ?? []
    }

    /// `POST /panel/api/setting/apiTokens/delete/:id`. The panel asks for the scope it expects (`admin`).
    public func deleteApiToken(id: Int) async throws {
        let body = Data(#"{"expectedScope":"admin"}"#.utf8)
        try await command(makeRequest(method: "POST", route: ["setting", "apiTokens", "delete", String(id)], body: body))
    }
}

/// Accepts any JSON value (the update route answers `obj: null` or `{"nodePending": true}`).
struct AnyDecodable: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

/// Building and sending requests, shared by `PanelClient` and the sign-in.
enum PanelRequest {
    static func make(
        base: URL, path: String, method: String, query: [URLQueryItem] = [], credential: PanelCredential?,
        headers: [CustomHeader], json: Data? = nil, form: [(String, String)]? = nil
    ) throws -> URLRequest {
        guard let url = requestURL(base: base, path: path, query: query) else {
            throw PanelError.invalidRequest("The panel URL is not valid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Custom headers first, so none of them can replace what the app sets below.
        for header in headers where header.validationError == nil {
            request.setValue(header.value.trimmingCharacters(in: .whitespacesAndNewlines),
                             forHTTPHeaderField: header.name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch credential {
        case .bearer(let token)?:
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .session(let cookie, let csrf)?:
            request.setValue("\(PanelClient.sessionCookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        case nil:
            break
        }
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let form {
            request.httpBody = Data(formEncode(form).utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// Sends the request and returns the body of a normal answer; throws the classified `PanelError` otherwise.
    static func perform(_ request: URLRequest, transport: any HTTPTransport, sessionMode: Bool) async throws -> Data {
        try await send(request, transport: transport, sessionMode: sessionMode).data
    }

    static func send(
        _ request: URLRequest, transport: any HTTPTransport, sessionMode: Bool
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw PanelWire.transportError(error)
        }
        if let failure = PanelWire.failure(
            status: response.statusCode, data: data,
            contentType: response.value(forHTTPHeaderField: "Content-Type"), sessionMode: sessionMode
        ) {
            throw failure
        }
        return (data, response)
    }
}
