import Foundation

public enum PanelError: Error, Equatable, LocalizedError {
    /// No answer: timeout, no route or DNS failure.
    case unreachable
    /// The TLS handshake failed: a bad, expired or mismatched certificate.
    case tls
    /// A proxy or firewall in front of the panel answered with a web page (HTML 403, 404 or a login wall).
    /// The network is refused; the token is not at fault.
    case refusedByProxy(Int)
    /// 401, or a session that expired: the credential no longer works.
    case unauthorized
    /// 403 from the panel itself: the token is valid but its scope does not allow the route.
    case forbidden(String)
    /// 404 without a web page: usually a wrong base path in the panel URL.
    case notFound
    case http(Int)
    /// HTTP 200 with `"success": false`.
    case api(String)
    case decoding
    /// The list was longer than the safety cap of pages.
    case incompleteList
    case invalidRequest(String)
    /// The sign-in form was refused: wrong user name, password or 2FA code.
    case signInFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: PanelMessages.unreachable
        case .tls: PanelMessages.tls
        case .refusedByProxy: PanelMessages.refused
        case .unauthorized: PanelMessages.unauthorized
        case .forbidden(let message): PanelMessages.forbidden(message)
        case .notFound: "The panel did not find this address. Check the base path in the panel URL."
        case .http(let status): "The panel answered HTTP \(status)."
        case .api(let message): message.isEmpty ? "The panel refused the request." : message
        case .decoding: "The panel answered something the app does not understand."
        case .incompleteList: "The client list is too long to load completely."
        case .invalidRequest(let why): why
        case .signInFailed(let message): message.isEmpty ? "The panel refused this user name or password." : message
        }
    }

    public var kind: FailureKind {
        switch self {
        case .unreachable: .unreachable
        case .tls: .tls
        case .refusedByProxy: .refused
        case .unauthorized: .unauthorized
        case .forbidden(let message): .forbidden(message)
        default: .other(errorDescription ?? "")
        }
    }
}

public enum PanelMessages {
    public static let unreachable = "The panel answers only on the home network, over the VPN or over Tailscale."
    public static let tls = "The secure connection to the panel failed. Its certificate is invalid, expired or for another name."
    public static let refused = "The server refused this network. The panel is reachable from your home network or through your VPN. "
        + "See \"Reaching the panel from outside\" in docs/APP.md on GitHub."
    public static let unauthorized = "The panel did not accept the saved sign-in. Sign in again."
    public static func forbidden(_ message: String) -> String {
        let reason = message.isEmpty ? "" : " (\(message))"
        return "This API token is not allowed to use this feature\(reason). Sign in with the admin account to make an admin token."
    }
    /// What the sign-in screen says about the missing sign-up.
    public static let noSignUp = "3x-ui has no sign-up. The admin account is created when the panel is installed."
}
