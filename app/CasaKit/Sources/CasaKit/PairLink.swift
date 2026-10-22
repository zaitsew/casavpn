import Foundation

public enum PairLinkError: Error, Equatable, LocalizedError {
    case notALink
    case wrongScheme
    case wrongAction
    case missing([String])
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .notALink:
            "This is not a link."
        case .wrongScheme, .wrongAction:
            "This is not a CasaVPN pairing link."
        case .missing(let names):
            "The pairing link is missing: \(names.joined(separator: ", "))."
        case .invalidURL(let name):
            "The \(name) in the pairing link must be an https URL."
        }
    }
}

/// Parses `casavpn://pair?panel=<url>&panelToken=<token>&relay=<url>&relayToken=<token>&sub=<url>`.
public enum PairLink {
    public static let scheme = "casavpn"
    public static let action = "pair"

    public static func parse(_ text: String) throws -> ConnectionSettings {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { throw PairLinkError.notALink }
        return try parse(url)
    }

    public static func parse(_ url: URL) throws -> ConnectionSettings {
        guard url.scheme?.lowercased() == scheme else { throw PairLinkError.wrongScheme }
        guard url.host?.lowercased() == action,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw PairLinkError.wrongAction }

        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, !value.isBlank, values[item.name] == nil {
                values[item.name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let required = ["panel", "panelToken", "relay", "relayToken", "sub"]
        let missing = required.filter { values[$0] == nil }
        guard missing.isEmpty else { throw PairLinkError.missing(missing) }

        for name in ["panel", "relay", "sub"] where ConnectionSettings.httpsURL(values[name] ?? "") == nil {
            throw PairLinkError.invalidURL(name)
        }

        return ConnectionSettings(
            panelURL: values["panel"] ?? "",
            panelToken: values["panelToken"] ?? "",
            relayURL: values["relay"] ?? "",
            relayToken: values["relayToken"] ?? "",
            subURL: values["sub"] ?? ""
        ).normalized()
    }
}
