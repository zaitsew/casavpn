import Foundation

public enum PanelError: Error, Equatable, LocalizedError {
    /// No answer: the panel is closed to this network (it answers only on the LAN, the VPN or Tailscale).
    case unreachable
    /// 401: the token is wrong, revoked or disabled.
    case unauthorized
    /// 403: a valid token whose scope does not allow the route (a monitor token on the clients routes).
    case forbidden(String)
    /// 404: usually a wrong base path in the panel URL.
    case notFound
    case http(Int)
    /// HTTP 200 with `"success": false`.
    case api(String)
    case decoding
    /// The list was longer than the safety cap of pages.
    case incompleteList
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: PanelMessages.unreachable
        case .unauthorized: "The panel rejected the API token."
        case .forbidden: PanelMessages.cannotListClients
        case .notFound: "The panel did not find this address. Check the base path in the panel URL."
        case .http(let status): "The panel answered HTTP \(status)."
        case .api(let message): message.isEmpty ? "The panel refused the request." : message
        case .decoding: "The panel answered something the app does not understand."
        case .incompleteList: "The client list is too long to load completely."
        case .invalidRequest(let why): why
        }
    }

    public var kind: FailureKind {
        switch self {
        case .unreachable: .unreachable
        case .unauthorized: .unauthorized
        case .forbidden(let message): .forbidden(message)
        default: .other(errorDescription ?? "")
        }
    }
}

public enum PanelMessages {
    /// The sentence docs/APP.md prescribes when the panel cannot be reached.
    public static let unreachable = "The panel answers only on the home network, over the VPN or over Tailscale."
    public static let cannotListClients = "This panel token cannot list clients. Create an admin token in the panel under Settings, API tokens."
}

/// The slice of the 3x-ui v3.10.2 API the app uses. The panel URL already carries the
/// base path; every route lives under `<panel URL>/panel/api/`. The token goes in
/// `Authorization: Bearer` (internal/web/controller/api.go, checkAPIAuth).
public struct PanelClient: Sendable {
    public static let pageSize = 200
    /// A safety cap, not a limit anyone should meet: 1,000 pages of 200 is 200,000 clients.
    public static let defaultMaxPages = 1_000

    public let baseURL: URL
    private let token: String
    private let transport: any HTTPTransport
    private let maxPages: Int

    public init(
        baseURL: URL,
        token: String,
        transport: any HTTPTransport = URLSessionTransport(),
        maxPages: Int = PanelClient.defaultMaxPages
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.maxPages = maxPages
    }

    public func makeRequest(
        method: String = "GET",
        route: [String],
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) throws -> URLRequest {
        let path = "/panel/api/" + route.map(encodePathSegment).joined(separator: "/")
        guard let url = requestURL(base: baseURL, path: path, query: query) else {
            throw PanelError.invalidRequest("The panel URL is not valid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw PanelError.unreachable
        }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw PanelError.unauthorized
        case 403:
            // {"success": false, "msg": "this API token is not permitted to access this endpoint"}
            let message = (try? JSONDecoder().decode(PanelEnvelope<String>.self, from: data))?.msg ?? ""
            throw PanelError.forbidden(message)
        case 404:
            throw PanelError.notFound
        default:
            throw PanelError.http(response.statusCode)
        }
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

    /// `GET /panel/api/server/status`. Allowed for admin and monitor tokens.
    public func serverStatus() async throws -> ServerStatus {
        try await object(ServerStatus.self, makeRequest(route: ["server", "status"]))
    }

    /// `GET /panel/api/clients/list/paged?page=&pageSize=`, all pages. Admin token only.
    /// The `online` emails come from the same answer (`summary.online`).
    public func clients() async throws -> ClientsSnapshot {
        var items: [VPNClient] = []
        var online: [String] = []
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
                return ClientsSnapshot(clients: items, online: Set(online))
            }
        }
        // Never hand back a silently partial list.
        throw PanelError.incompleteList
    }

    /// Builds the body that turns a client on or off. See `ClientUpdateBody`.
    func makeUpdateRequest(record: ClientRecordPayload.Record, enable: Bool) throws -> URLRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(ClientUpdateBody(from: record, enable: enable))
        return try makeRequest(method: "POST", route: ["clients", "update", record.email], body: body)
    }

    /// Turns one client on or off: `GET /clients/get/:email` for the current record, then
    /// `POST /clients/update/:email` with the same record and `enable` changed.
    /// Not verified against a live panel (docs/APP.md notes it).
    public func setClientEnabled(email: String, enabled: Bool) async throws {
        let current = try await object(ClientRecordPayload.self, makeRequest(route: ["clients", "get", email]))
        try await command(makeUpdateRequest(record: current.client, enable: enabled))
    }

    /// Sends a request whose answer carries no object we need (`obj` is null or `{"nodePending": true}`).
    private func command(_ request: URLRequest) async throws {
        let data = try await perform(request)
        let envelope: PanelEnvelope<AnyDecodable>
        do { envelope = try JSONDecoder().decode(PanelEnvelope<AnyDecodable>.self, from: data) } catch { throw PanelError.decoding }
        guard envelope.success else { throw PanelError.api(envelope.msg ?? "") }
    }
}

/// Accepts any JSON value (the update route answers `obj: null` or `{"nodePending": true}`).
struct AnyDecodable: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}
