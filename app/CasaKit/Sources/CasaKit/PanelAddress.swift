import Foundation

/// Turns what a person types or pastes into the panel's base URL.
///
/// The panel is reached at `https://<host>:<port>/<base path>/`. People paste the address bar of
/// the browser, which may end in `/panel/`, `/panel/inbounds` or `/login`; the app needs only the
/// part before that.
public enum PanelAddress {
    public enum Problem: Error, Equatable, LocalizedError {
        case empty
        case notHTTPS
        case invalid

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter the address of your 3x-ui panel."
            case .notHTTPS: "The app talks to the panel over https only. Use an address that starts with https://."
            case .invalid: "This does not look like a panel address. Example: https://vpn.example.com:8443/your-path"
            }
        }
    }

    /// `https://host:port/base`, with no query, no fragment, no trailing slash and no `/panel/...` or `/login` tail.
    public static func normalize(_ text: String) throws -> String {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { throw Problem.empty }
        if !input.contains("://") { input = "https://" + input }
        guard var components = URLComponents(string: input), let scheme = components.scheme?.lowercased() else {
            throw Problem.invalid
        }
        guard scheme == "https" else { throw scheme == "http" ? Problem.notHTTPS : Problem.invalid }
        guard let host = components.host, !host.isEmpty, host.contains(".") || host.contains(":") || host == "localhost"
        else { throw Problem.invalid }
        components.scheme = "https"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let index = segments.firstIndex(of: "panel") {
            segments.removeSubrange(index...)
        } else if segments.last == "login" {
            segments.removeLast()
        }
        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let url = components.url else { throw Problem.invalid }
        var result = url.absoluteString
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
