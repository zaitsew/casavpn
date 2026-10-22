import Foundation

public enum RelayError: Error, Equatable, LocalizedError {
    case unreachable
    case unauthorized
    case http(Int)
    case decoding
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: "The relay did not answer."
        case .unauthorized: "The relay rejected the app token."
        case .http(let status): "The relay answered HTTP \(status)."
        case .decoding: "The relay answered something the app does not understand."
        case .invalidRequest(let why): why
        }
    }

    public var kind: FailureKind {
        switch self {
        case .unreachable: .unreachable
        case .unauthorized: .unauthorized
        default: .other(errorDescription ?? "")
        }
    }
}

/// The relay API of docs/APP.md. The app token goes in `Authorization: Bearer`.
public struct RelayClient: Sendable {
    public static let defaultAlertLimit = 50

    public enum Endpoint: Equatable, Sendable {
        case registerDevice(DeviceRegistration)
        case deleteDevice(token: String)
        case alerts(limit: Int)
        case test
    }

    public let baseURL: URL
    private let token: String
    private let transport: any HTTPTransport

    public init(baseURL: URL, token: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    /// Builds the request without sending it (the tests read it).
    public func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        let method: String
        let path: String
        var query: [URLQueryItem] = []
        var body: Data?

        switch endpoint {
        case .registerDevice(let registration):
            guard DeviceToken.isHex(registration.token) else {
                throw RelayError.invalidRequest("The device token is not hexadecimal.")
            }
            method = "POST"; path = "/v1/devices"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            body = try encoder.encode(registration)
        case .deleteDevice(let deviceToken):
            guard DeviceToken.isHex(deviceToken) else {
                throw RelayError.invalidRequest("The device token is not hexadecimal.")
            }
            method = "DELETE"; path = "/v1/devices/" + encodePathSegment(deviceToken)
        case .alerts(let limit):
            method = "GET"; path = "/v1/alerts"
            query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        case .test:
            method = "POST"; path = "/v1/test"
        }

        guard let url = requestURL(base: baseURL, path: path, query: query) else {
            throw RelayError.invalidRequest("The relay URL is not valid.")
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

    private func perform(_ endpoint: Endpoint) async throws -> Data {
        let request = try makeRequest(endpoint)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw RelayError.unreachable
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw RelayError.unauthorized
        default: throw RelayError.http(response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONCoding.decoder().decode(type, from: data) } catch { throw RelayError.decoding }
    }

    /// `POST /v1/devices` -> 204. Registering the same token again updates it.
    public func registerDevice(_ registration: DeviceRegistration) async throws {
        _ = try await perform(.registerDevice(registration))
    }

    /// `DELETE /v1/devices/<hex>` -> 204.
    public func deleteDevice(token deviceToken: String) async throws {
        _ = try await perform(.deleteDevice(token: deviceToken))
    }

    /// `GET /v1/alerts?limit=` -> the history, newest first, and the monitor state.
    public func alerts(limit: Int = RelayClient.defaultAlertLimit) async throws -> AlertsResponse {
        try decode(AlertsResponse.self, from: try await perform(.alerts(limit: limit)))
    }

    /// `POST /v1/test` -> 202.
    public func sendTest() async throws -> PushResult {
        try decode(PushResult.self, from: try await perform(.test))
    }
}
