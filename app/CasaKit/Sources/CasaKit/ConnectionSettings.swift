import Foundation

/// One extra HTTP header sent with every panel request, for a proxy in front of the panel
/// (for example the `CF-Access-Client-Id` and `CF-Access-Client-Secret` of a Cloudflare
/// Access service token). The values are secrets: they live in the Keychain item.
public struct CustomHeader: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public var id: String { name.lowercased() }

    /// Headers the app sets itself. A custom header must not replace them.
    static let reserved: Set<String> = [
        "authorization", "cookie", "host", "content-length", "content-type", "accept",
        "x-csrf-token", "x-requested-with",
    ]

    /// An HTTP token as the name (letters, digits and `-` only) and a value without control characters.
    public var validationError: String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "A header needs a name." }
        if n.count > 64 || n.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) == nil {
            return "A header name may contain only letters, digits and hyphens."
        }
        if Self.reserved.contains(n.lowercased()) { return "\(n) is set by the app and cannot be replaced." }
        if v.isEmpty { return "The header \(n) needs a value." }
        if v.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            return "The value of \(n) contains a control character."
        }
        return nil
    }
}

/// How the app proves itself to the panel.
public enum PanelCredential: Equatable, Sendable {
    /// An API token: `Authorization: Bearer`. It skips the panel's CSRF check.
    case bearer(String)
    /// The fallback when a token could not be made: the panel's session cookie and CSRF token.
    case session(cookie: String, csrf: String)
}

/// The connection details of the app (docs/APP.md, "The app"). All of them live in ONE
/// Keychain item, never in `UserDefaults`. The sign-in password is not among them: the app
/// uses it once to make its own API token and drops it.
public struct ConnectionSettings: Equatable, Codable, Sendable {
    /// `https://vpn.example.com:8443/<base path>`
    public var panelURL: String
    /// A 3x-ui API token: the one the app made at sign-in, or one pasted or paired.
    public var panelToken: String
    /// The relay Worker's URL.
    public var relayURL: String
    /// The relay's `APP_TOKEN`.
    public var relayToken: String
    /// `https://vpn.example.com:8443/sub/`; the client's subId is appended.
    public var subURL: String

    /// The panel user the app signed in as. Shown in Settings; empty for a pasted or paired token.
    public var panelUser: String
    /// The id of the API token the app made on the panel, so Sign out can delete it. 0 = not made by the app.
    public var panelTokenID: Int
    public var panelTokenName: String
    /// Fallback when token creation was not possible: the panel session (cookie value) and its CSRF token.
    public var panelSession: String
    public var panelCSRF: String
    /// Extra headers for every panel request (Cloudflare Access service token).
    public var panelHeaders: [CustomHeader]

    public init(
        panelURL: String = "",
        panelToken: String = "",
        relayURL: String = "",
        relayToken: String = "",
        subURL: String = "",
        panelUser: String = "",
        panelTokenID: Int = 0,
        panelTokenName: String = "",
        panelSession: String = "",
        panelCSRF: String = "",
        panelHeaders: [CustomHeader] = []
    ) {
        self.panelURL = panelURL
        self.panelToken = panelToken
        self.relayURL = relayURL
        self.relayToken = relayToken
        self.subURL = subURL
        self.panelUser = panelUser
        self.panelTokenID = panelTokenID
        self.panelTokenName = panelTokenName
        self.panelSession = panelSession
        self.panelCSRF = panelCSRF
        self.panelHeaders = panelHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case panelURL, panelToken, relayURL, relayToken, subURL
        case panelUser, panelTokenID, panelTokenName, panelSession, panelCSRF, panelHeaders
    }

    /// Every field is optional on disk: an item written by an older version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panelURL = try c.decodeIfPresent(String.self, forKey: .panelURL) ?? ""
        panelToken = try c.decodeIfPresent(String.self, forKey: .panelToken) ?? ""
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? ""
        relayToken = try c.decodeIfPresent(String.self, forKey: .relayToken) ?? ""
        subURL = try c.decodeIfPresent(String.self, forKey: .subURL) ?? ""
        panelUser = try c.decodeIfPresent(String.self, forKey: .panelUser) ?? ""
        panelTokenID = try c.decodeIfPresent(Int.self, forKey: .panelTokenID) ?? 0
        panelTokenName = try c.decodeIfPresent(String.self, forKey: .panelTokenName) ?? ""
        panelSession = try c.decodeIfPresent(String.self, forKey: .panelSession) ?? ""
        panelCSRF = try c.decodeIfPresent(String.self, forKey: .panelCSRF) ?? ""
        panelHeaders = try c.decodeIfPresent([CustomHeader].self, forKey: .panelHeaders) ?? []
    }

    public static let empty = ConnectionSettings()

    /// Trims whitespace and drops trailing slashes from the panel and relay URLs.
    /// The subscription URL keeps its trailing slash (`subscriptionLink` adds one if absent).
    public func normalized() -> ConnectionSettings {
        var copy = self
        copy.panelURL = Self.stripTrailingSlashes(panelURL.trimmingCharacters(in: .whitespacesAndNewlines))
        copy.panelToken = panelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.relayURL = Self.stripTrailingSlashes(relayURL.trimmingCharacters(in: .whitespacesAndNewlines))
        copy.relayToken = relayToken.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.subURL = subURL.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.panelUser = panelUser.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.panelTokenName = panelTokenName.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.panelSession = panelSession.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.panelCSRF = panelCSRF.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.panelHeaders = panelHeaders
            .map { CustomHeader(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !($0.name.isEmpty && $0.value.isEmpty) }
        return copy
    }

    public var panelBase: URL? { Self.httpsURL(panelURL) }
    public var relayBase: URL? { Self.httpsURL(relayURL) }
    public var subBase: URL? { Self.httpsURL(subURL) }

    /// The credential the panel client uses; a token wins over a session.
    public var panelCredential: PanelCredential? {
        if !panelToken.isBlank { return .bearer(panelToken) }
        if !panelSession.isBlank { return .session(cookie: panelSession, csrf: panelCSRF) }
        return nil
    }

    /// The panel parts of the app need a valid URL and a credential.
    public var hasPanel: Bool { panelBase != nil && panelCredential != nil }
    /// The relay parts of the app need a valid URL and a token.
    public var hasRelay: Bool { relayBase != nil && !relayToken.isBlank }

    /// True when the app made its own API token and can delete it again.
    public var ownsPanelToken: Bool { panelTokenID > 0 && !panelToken.isBlank }

    /// The first invalid header's message, if any.
    public var headerError: String? {
        for header in panelHeaders {
            if header.name.isBlank && header.value.isBlank { continue }
            if let error = header.validationError { return error }
        }
        return nil
    }

    /// `<sub base URL><subId>`. Nil when the base is not a valid https URL or the subId is empty.
    public func subscriptionLink(subId: String) -> String? {
        let id = subId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = subBase, !id.isEmpty else { return nil }
        var text = base.absoluteString
        if !text.hasSuffix("/") { text += "/" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return text + encoded
    }

    /// Accepts only `https` URLs with a host. The app has no ATS exceptions.
    public static func httpsURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    private static func stripTrailingSlashes(_ text: String) -> String {
        var result = text
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
