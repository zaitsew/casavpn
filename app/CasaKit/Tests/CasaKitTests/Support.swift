import Foundation
@testable import CasaKit

/// Answers requests from a queue and records what was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Reply {
        case response(status: Int, body: String)
        case failure(URLError.Code)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var sent: [URLRequest] = []

    init(_ replies: Reply...) { self.replies = replies }
    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply = {
            lock.lock(); defer { lock.unlock() }
            sent.append(request)
            return replies.isEmpty ? .response(status: 500, body: "") : replies.removeFirst()
        }()
        switch reply {
        case .failure(let code):
            throw URLError(code)
        case .response(let status, let body):
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), http)
        }
    }
}

extension URLRequest {
    var bodyText: String { String(decoding: httpBody ?? Data(), as: UTF8.self) }
}

let relayURL = URL(string: "https://casavpn-monitor.example.workers.dev")!
let panelURL = URL(string: "https://vpn.example.com:8443/secret-path")!
