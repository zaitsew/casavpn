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

/// Reads and writes the five connection details as five Keychain items.
public struct SettingsStore: Sendable {
    public enum Key {
        public static let panelURL = "panelURL"
        public static let panelToken = "panelToken"
        public static let relayURL = "relayURL"
        public static let relayToken = "relayToken"
        public static let subURL = "subURL"
    }

    private let secrets: any SecretStore

    public init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
    }

    public func load() -> ConnectionSettings {
        ConnectionSettings(
            panelURL: secrets.read(Key.panelURL) ?? "",
            panelToken: secrets.read(Key.panelToken) ?? "",
            relayURL: secrets.read(Key.relayURL) ?? "",
            relayToken: secrets.read(Key.relayToken) ?? "",
            subURL: secrets.read(Key.subURL) ?? ""
        )
    }

    public func save(_ settings: ConnectionSettings) throws {
        let s = settings.normalized()
        try secrets.write(s.panelURL, for: Key.panelURL)
        try secrets.write(s.panelToken, for: Key.panelToken)
        try secrets.write(s.relayURL, for: Key.relayURL)
        try secrets.write(s.relayToken, for: Key.relayToken)
        try secrets.write(s.subURL, for: Key.subURL)
    }
}
