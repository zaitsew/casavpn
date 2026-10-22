import Foundation
import Testing
@testable import CasaKit

@Suite("PairLink")
struct PairLinkTests {
    static let good = "casavpn://pair?panel=https%3A%2F%2Fvpn.example.com%3A8443%2Fabc&panelToken=ptok"
        + "&relay=https%3A%2F%2Frelay.example.com&relayToken=rtok&sub=https%3A%2F%2Fvpn.example.com%3A8443%2Fsub%2F"

    @Test func parsesAGoodLink() throws {
        let s = try PairLink.parse(Self.good)
        #expect(s.panelURL == "https://vpn.example.com:8443/abc")
        #expect(s.panelToken == "ptok")
        #expect(s.relayURL == "https://relay.example.com")
        #expect(s.relayToken == "rtok")
        #expect(s.subURL == "https://vpn.example.com:8443/sub/")
        #expect(s.hasPanel && s.hasRelay)
    }

    @Test func acceptsUnencodedValuesAndSurroundingWhitespace() throws {
        let text = "  casavpn://pair?panel=https://vpn.example.com:8443/abc/&panelToken=p&relay=https://r.example.com/&relayToken=r&sub=https://vpn.example.com:8443/sub/\n"
        let s = try PairLink.parse(text)
        #expect(s.panelURL == "https://vpn.example.com:8443/abc")
        #expect(s.relayURL == "https://r.example.com")
    }

    @Test func reportsEveryMissingField() {
        let text = "casavpn://pair?panel=https%3A%2F%2Fvpn.example.com&relay=https%3A%2F%2Fr.example.com"
        #expect(throws: PairLinkError.missing(["panelToken", "relayToken", "sub"])) { try PairLink.parse(text) }
    }

    @Test func emptyValueCountsAsMissing() {
        let text = Self.good.replacingOccurrences(of: "panelToken=ptok", with: "panelToken=")
        #expect(throws: PairLinkError.missing(["panelToken"])) { try PairLink.parse(text) }
    }

    @Test func rejectsPlainHttp() {
        let text = Self.good.replacingOccurrences(of: "https%3A%2F%2Frelay.example.com", with: "http%3A%2F%2Frelay.example.com")
        #expect(throws: PairLinkError.invalidURL("relay")) { try PairLink.parse(text) }
    }

    @Test func rejectsOtherSchemesAndActions() {
        #expect(throws: PairLinkError.wrongScheme) { try PairLink.parse("https://example.com/pair?panel=x") }
        #expect(throws: PairLinkError.wrongAction) { try PairLink.parse("casavpn://other?panel=x") }
    }

    @Test func rejectsTextThatIsNotAURL() {
        #expect(throws: PairLinkError.notALink) { try PairLink.parse("hello world") }
        #expect(throws: PairLinkError.notALink) { try PairLink.parse("") }
    }

    @Test func firstValueWinsForRepeatedNames() throws {
        let s = try PairLink.parse(Self.good + "&panelToken=other")
        #expect(s.panelToken == "ptok")
    }
}

@Suite("ConnectionSettings and SettingsStore")
struct SettingsTests {
    @Test func subscriptionLinkAppendsTheSubId() {
        let s = ConnectionSettings(subURL: "https://vpn.example.com:8443/sub/")
        #expect(s.subscriptionLink(subId: "abc123") == "https://vpn.example.com:8443/sub/abc123")
    }

    @Test func subscriptionLinkAddsTheMissingSlashAndEncodes() {
        let s = ConnectionSettings(subURL: "https://vpn.example.com:8443/sub")
        #expect(s.subscriptionLink(subId: "a b/c") == "https://vpn.example.com:8443/sub/a%20b%2Fc")
        #expect(s.subscriptionLink(subId: "  ") == nil)
        #expect(ConnectionSettings(subURL: "http://x.example.com/").subscriptionLink(subId: "a") == nil)
    }

    @Test func normalizedTrimsAndDropsTrailingSlashes() {
        let s = ConnectionSettings(panelURL: " https://vpn.example.com:8443/p// ", panelToken: " t ", relayURL: "https://r.example.com/").normalized()
        #expect(s.panelURL == "https://vpn.example.com:8443/p")
        #expect(s.panelToken == "t")
        #expect(s.relayURL == "https://r.example.com")
    }

    @Test func hasPanelNeedsAnHttpsURLAndAToken() {
        #expect(!ConnectionSettings(panelURL: "https://vpn.example.com").hasPanel)
        #expect(!ConnectionSettings(panelURL: "http://vpn.example.com", panelToken: "t").hasPanel)
        #expect(ConnectionSettings(panelURL: "https://vpn.example.com", panelToken: "t").hasPanel)
    }

    @Test func storeKeepsTheWholeSetInOneItem() throws {
        let memory = InMemorySecretStore()
        let store = SettingsStore(secrets: memory)
        let settings = ConnectionSettings(panelURL: "https://vpn.example.com/p", panelToken: "a", relayURL: "https://r.example.com", relayToken: "b", subURL: "https://vpn.example.com/sub/")
        try store.save(settings)
        #expect(store.load() == settings)
        #expect(memory.keys == ["connection"])
        try store.save(.empty)
        #expect(store.load() == .empty)
        #expect(memory.keys.isEmpty)
    }

    @Test func deleteAllRemovesEveryItemOfTheServer() throws {
        let memory = InMemorySecretStore()
        let store = SettingsStore(secrets: memory)
        var settings = ConnectionSettings(
            panelURL: "https://vpn.example.com/p", panelToken: "tok", relayURL: "https://r.example.com",
            relayToken: "rt", subURL: "https://vpn.example.com/sub/"
        )
        settings.panelUser = "admin"
        settings.panelSession = "cookie"
        settings.panelCSRF = "csrf"
        settings.panelHeaders = [CustomHeader(name: "CF-Access-Client-Id", value: "id.example"), CustomHeader(name: "CF-Access-Client-Secret", value: "secret")]
        try store.save(settings)
        // Items of the first app versions that were never migrated.
        try memory.write("https://old.example.com", for: "panelURL")
        try memory.write("old-token", for: "relayToken")
        #expect(!memory.keys.isEmpty)
        try store.deleteAll()
        #expect(memory.keys.isEmpty)
        #expect(store.load() == .empty)
    }
}

@Suite("Sign-out wipe")
struct SignOutWipeTests {
    @Test func aFailedDeleteIsReportedWithWhatIsStillStoredThenRetried() throws {
        let flaky = FlakySecretStore()
        let store = SettingsStore(secrets: flaky)
        var settings = ConnectionSettings(panelURL: "https://vpn.example.com/p", panelToken: "tok", relayURL: "https://r.example.com", relayToken: "rt")
        settings.panelHeaders = [CustomHeader(name: "CF-Access-Client-Id", value: "id.example")]
        try store.save(settings)

        flaky.failWrites = true
        #expect(store.deleteAllRetrying(attempts: 2) != nil)
        let left = store.storedItems()
        #expect(left.contains("the panel API token"))
        #expect(left.contains("the extra request headers"))
        #expect(left.contains("the relay token"))

        // The retry (the next launch) succeeds once the Keychain answers again.
        flaky.failWrites = false
        #expect(store.deleteAllRetrying() == nil)
        #expect(store.storedItems().isEmpty)
        #expect(flaky.inner.keys.isEmpty)
    }
}

@Suite("Sign-out wipe of legacy items")
struct LegacyWipeTests {
    @Test func aLegacyItemThatCannotBeDeletedFailsTheWipe() throws {
        let stubborn = StubbornKeySecretStore(key: "panelToken")
        try stubborn.inner.write("old-token", for: "panelToken")
        let store = SettingsStore(secrets: stubborn)
        #expect(throws: KeychainError.self) { try store.deleteAll() }
        #expect(store.deleteAllRetrying(attempts: 2) != nil)
        #expect(store.storedItems().contains("the panel API token"))
    }
}

/// A store that cannot delete one key.
final class StubbornKeySecretStore: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    let key: String
    init(key: String) { self.key = key }
    func read(_ key: String) -> String? { inner.read(key) }
    func write(_ value: String?, for key: String) throws {
        if value == nil, key == self.key { throw KeychainError.status(-25308) }
        try inner.write(value, for: key)
    }
}

/// A store whose writes can be made to fail.
final class FlakySecretStore: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    private let lock = NSLock()
    private var failing = false
    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }
    func read(_ key: String) -> String? { inner.read(key) }
    func write(_ value: String?, for key: String) throws {
        if failWrites { throw KeychainError.status(-25308) }
        try inner.write(value, for: key)
    }
}

@Suite("SettingsStore atomicity")
struct SettingsAtomicityTests {
    let first = ConnectionSettings(panelURL: "https://a.example.com/p", panelToken: "tokA", relayURL: "https://ra.example.com", relayToken: "rA", subURL: "https://a.example.com/sub/")
    let second = ConnectionSettings(panelURL: "https://b.example.com/p", panelToken: "tokB", relayURL: "https://rb.example.com", relayToken: "rB", subURL: "https://b.example.com/sub/")

    @Test func aFailedSaveLeavesThePreviousCompleteSet() throws {
        let flaky = FlakySecretStore()
        let store = SettingsStore(secrets: flaky)
        try store.save(first)
        flaky.failWrites = true
        #expect(throws: KeychainError.self) { try store.save(second) }
        flaky.failWrites = false
        // Never the new URL with the old token.
        #expect(store.load() == first)
    }

    @Test func aSaveIsOneWrite() throws {
        let flaky = FlakySecretStore()
        try SettingsStore(secrets: flaky).save(second)
        #expect(flaky.inner.keys == ["connection"])
    }

    @Test func legacyItemsAreMigratedThenDeleted() throws {
        let memory = InMemorySecretStore()
        try memory.write(first.panelURL, for: "panelURL")
        try memory.write(first.panelToken, for: "panelToken")
        try memory.write(first.relayURL, for: "relayURL")
        try memory.write(first.relayToken, for: "relayToken")
        try memory.write(first.subURL, for: "subURL")
        let store = SettingsStore(secrets: memory)
        #expect(store.load() == first)
        #expect(memory.keys == ["connection"])
        #expect(store.load() == first)
    }

    @Test func aFailedMigrationKeepsTheLegacyItems() throws {
        let flaky = FlakySecretStore()
        try flaky.inner.write(first.panelURL, for: "panelURL")
        try flaky.inner.write(first.panelToken, for: "panelToken")
        try flaky.inner.write(first.relayURL, for: "relayURL")
        try flaky.inner.write(first.relayToken, for: "relayToken")
        flaky.failWrites = true
        let store = SettingsStore(secrets: flaky)
        #expect(store.load().panelToken == "tokA")
        #expect(flaky.inner.keys == ["panelToken", "panelURL", "relayToken", "relayURL"])
        flaky.failWrites = false
        #expect(store.load().relayToken == "rA")
        #expect(flaky.inner.keys == ["connection"])
    }

    @Test func aCorruptItemReadsAsEmpty() throws {
        let memory = InMemorySecretStore()
        try memory.write("not json", for: "connection")
        #expect(SettingsStore(secrets: memory).load() == .empty)
    }
}

@Suite("SnapshotSequencer")
struct SequencerTests {
    @Test func anOlderAnswerNeverReplacesANewerOne() {
        var s = SnapshotSequencer()
        let a = s.begin()
        let b = s.begin()
        let acceptedB = s.accept(b)
        let acceptedA = s.accept(a)
        let c = s.begin()
        let acceptedC = s.accept(c)
        #expect(acceptedB)
        #expect(!acceptedA)
        #expect(acceptedC)
    }

    @Test func answersInOrderAreAllAccepted() {
        var s = SnapshotSequencer()
        let a = s.begin()
        let acceptedA = s.accept(a)
        let b = s.begin()
        let acceptedB = s.accept(b)
        let again = s.accept(b)
        #expect(acceptedA && acceptedB)
        #expect(!again)
    }
}
