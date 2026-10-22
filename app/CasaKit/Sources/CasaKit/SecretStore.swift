import Foundation
import Security

/// Where the connection details live. The app uses the Keychain; tests use memory.
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    /// A nil or empty value deletes the item.
    func write(_ value: String?, for key: String) throws
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let code): "The Keychain refused the change (error \(code))."
        }
    }
}

/// Generic-password items, readable after the first unlock, never synced or backed up.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "casavpn") {
        self.service = service
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    public func read(_ key: String) -> String? {
        var q = query(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String?, for key: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query(for: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(for: key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = query(for: key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}

/// A store for tests and previews.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init() {}

    public func read(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    public func write(_ value: String?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty { items[key] = value } else { items[key] = nil }
    }

    public var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.keys.sorted()
    }
}

/// Reads and writes the five connection details as ONE Keychain item (a JSON blob), so a
/// save either replaces the whole set or leaves the previous complete set untouched. Five
/// separate items could be left half-written: a new URL with the old token would send that
/// token to the new server.
public struct SettingsStore: Sendable {
    public enum Key {
        public static let connection = "connection"
        /// The per-field items of the first versions. Read once, migrated, then deleted.
        static let legacy = ["panelURL", "panelToken", "relayURL", "relayToken", "subURL"]
    }

    private let secrets: any SecretStore

    public init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
    }

    public func load() -> ConnectionSettings {
        if let text = secrets.read(Key.connection),
           let settings = try? JSONDecoder().decode(ConnectionSettings.self, from: Data(text.utf8)) {
            return settings
        }
        return migrateLegacy() ?? .empty
    }

    /// Writes the complete set in one Keychain call. Throws, with the old set still in place, if that fails.
    public func save(_ settings: ConnectionSettings) throws {
        let normalized = settings.normalized()
        if normalized == .empty {
            try secrets.write(nil, for: Key.connection)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(normalized)
            try secrets.write(String(decoding: data, as: UTF8.self), for: Key.connection)
        }
        for key in Key.legacy { try? secrets.write(nil, for: key) }
    }

    /// Old per-field items -> the blob. The blob is written first; the old items are deleted
    /// only after that succeeded, so a failure loses nothing.
    private func migrateLegacy() -> ConnectionSettings? {
        let old = ConnectionSettings(
            panelURL: secrets.read("panelURL") ?? "",
            panelToken: secrets.read("panelToken") ?? "",
            relayURL: secrets.read("relayURL") ?? "",
            relayToken: secrets.read("relayToken") ?? "",
            subURL: secrets.read("subURL") ?? ""
        )
        guard old != .empty else { return nil }
        try? save(old)
        return old
    }
}
