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

    @Test func storeRoundTripsThroughFiveSeparateItems() throws {
        let memory = InMemorySecretStore()
        let store = SettingsStore(secrets: memory)
        let settings = ConnectionSettings(panelURL: "https://vpn.example.com/p", panelToken: "a", relayURL: "https://r.example.com", relayToken: "b", subURL: "https://vpn.example.com/sub/")
        try store.save(settings)
        #expect(store.load() == settings)
        #expect(memory.keys == ["panelToken", "panelURL", "relayToken", "relayURL", "subURL"])
        try store.save(.empty)
        #expect(store.load() == .empty)
        #expect(memory.keys.isEmpty)
    }
}
