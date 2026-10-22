import Foundation

/// The one seam between the clients and the network. Production uses a plain
/// `URLSession` with the system's default trust (Let's Encrypt works; there are no
/// ATS exceptions and no pinning). Tests use a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 12) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    /// Cancels every request in flight and refuses new ones. Make a new transport afterwards.
    public func cancelAll() {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// How a failure should be presented, shared by the relay and the panel errors.
public enum FailureKind: Equatable, Sendable {
    /// The server could not be reached (timeout, no route, DNS).
    case unreachable
    /// The TLS handshake failed (bad, expired or mismatched certificate).
    case tls
    /// A proxy in front of the panel answered with a web page (403, 404, a login wall):
    /// the network is refused, the token is not at fault.
    case refused
    /// 401: the token or the session is wrong, revoked, disabled or expired.
    case unauthorized
    /// 403 from the panel itself: the token is valid but its scope does not allow the request.
    case forbidden(String)
    case other(String)
}

enum JSONCoding {
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    static func parseDate(_ text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }
}

/// Percent-encodes one URL path segment (an email address, a device token).
func encodePathSegment(_ text: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove("/")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
}

func requestURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
    var text = base.absoluteString
    while text.hasSuffix("/") { text.removeLast() }
    guard var components = URLComponents(string: text + path) else { return nil }
    if !query.isEmpty { components.queryItems = query }
    return components.url
}
