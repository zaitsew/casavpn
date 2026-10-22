import Foundation

/// Reading the HTTP side of a panel answer: which failures mean what.
enum PanelWire {
    /// True when the body is a web page. The panel's API answers JSON; HTML comes from a proxy,
    /// a firewall page or an access gateway in front of it.
    static func looksLikeHTML(_ data: Data, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("text/html") { return true }
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype") || head.hasPrefix("<html") || head.hasPrefix("<head") || head.hasPrefix("<body")
    }

    /// Maps a failed `URLSession` call.
    static func transportError(_ error: Error) -> PanelError {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return .tls
            default:
                return .unreachable
            }
        }
        return .unreachable
    }

    /// The error for a response, or nil when the response is a normal answer (2xx with JSON).
    /// `sessionMode` is true when the request used the panel session instead of a token: an empty 403
    /// is then the CSRF check failing, which means the session expired.
    static func failure(status: Int, data: Data, contentType: String?, sessionMode: Bool) -> PanelError? {
        let html = looksLikeHTML(data, contentType: contentType)
        switch status {
        case 200..<300:
            return html ? .refusedByProxy(status) : nil
        case 300..<400:
            return .redirected(status)
        case 401:
            return html ? .refusedByProxy(status) : .unauthorized
        case 403:
            if html { return .refusedByProxy(403) }
            if let envelope = try? JSONDecoder().decode(PanelEnvelope<AnyDecodable>.self, from: data), envelope.msg != nil || !envelope.success,
               !data.isEmpty {
                return .forbidden(envelope.msg ?? "")
            }
            // An empty 403: the panel's CSRF check on a session, or a proxy that sends no body.
            return sessionMode ? .unauthorized : .refusedByProxy(403)
        case 404:
            return html ? .refusedByProxy(404) : .notFound
        default:
            return html && (400..<500).contains(status) ? .refusedByProxy(status) : .http(status)
        }
    }

    /// Reads one cookie from a response's `Set-Cookie` headers.
    static func cookie(named name: String, in response: HTTPURLResponse) -> String? {
        guard let url = response.url else { return nil }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first { $0.name == name && !$0.value.isEmpty }?.value
    }
}
