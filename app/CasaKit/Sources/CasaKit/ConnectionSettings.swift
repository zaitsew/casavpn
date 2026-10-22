import Foundation

/// The five connection details of the app (docs/APP.md, "The app").
/// All of them live in the Keychain, never in `UserDefaults`.
public struct ConnectionSettings: Equatable, Sendable {
    /// `https://vpn.example.com:8443/<base path>`
    public var panelURL: String
    /// A 3x-ui API token (Settings -> API tokens in the panel).
    public var panelToken: String
    /// The relay Worker's URL.
    public var relayURL: String
    /// The relay's `APP_TOKEN`.
    public var relayToken: String
    /// `https://vpn.example.com:8443/sub/`; the client's subId is appended.
    public var subURL: String

    public init(
        panelURL: String = "",
        panelToken: String = "",
        relayURL: String = "",
        relayToken: String = "",
        subURL: String = ""
    ) {
        self.panelURL = panelURL
        self.panelToken = panelToken
        self.relayURL = relayURL
        self.relayToken = relayToken
        self.subURL = subURL
    }

    public static let empty = ConnectionSettings()

    /// Trims whitespace and drops trailing slashes from the panel and relay URLs.
    /// The subscription URL keeps its trailing slash (`subscriptionLink` adds one if absent).
    public func normalized() -> ConnectionSettings {
        ConnectionSettings(
            panelURL: Self.stripTrailingSlashes(panelURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            panelToken: panelToken.trimmingCharacters(in: .whitespacesAndNewlines),
            relayURL: Self.stripTrailingSlashes(relayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            relayToken: relayToken.trimmingCharacters(in: .whitespacesAndNewlines),
            subURL: subURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public var panelBase: URL? { Self.httpsURL(panelURL) }
    public var relayBase: URL? { Self.httpsURL(relayURL) }
    public var subBase: URL? { Self.httpsURL(subURL) }

    /// The panel parts of the app need a valid URL and a token.
    public var hasPanel: Bool { panelBase != nil && !panelToken.isBlank }
    /// The relay parts of the app need a valid URL and a token.
    public var hasRelay: Bool { relayBase != nil && !relayToken.isBlank }

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
