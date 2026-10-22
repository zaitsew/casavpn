import Foundation
import Testing
@testable import CasaKit

@Suite("ConnectionSettings v2")
struct ConnectionSettingsTests {
    @Test func anItemWrittenByTheFirstVersionStillLoads() throws {
        let old = #"{"panelURL": "https://vpn.example.com:8443/p", "panelToken": "t", "relayURL": "", "relayToken": "", "subURL": ""}"#
        let settings = try JSONDecoder().decode(ConnectionSettings.self, from: Data(old.utf8))
        #expect(settings.panelToken == "t")
        #expect(settings.panelHeaders.isEmpty)
        #expect(settings.panelTokenID == 0)
        #expect(!settings.ownsPanelToken)
        #expect(settings.hasPanel)
    }

    @Test func headersAndSessionSurviveARoundTrip() throws {
        let settings = ConnectionSettings(
            panelURL: "https://vpn.example.com:8443/p", panelSession: "cookie", panelCSRF: "csrf",
            panelHeaders: [CustomHeader(name: "CF-Access-Client-Id", value: "id")]
        )
        let again = try JSONDecoder().decode(ConnectionSettings.self, from: try JSONEncoder().encode(settings))
        #expect(again == settings)
        #expect(again.panelCredential == .session(cookie: "cookie", csrf: "csrf"))
    }

    @Test func aTokenWinsOverASession() {
        let settings = ConnectionSettings(panelURL: "https://vpn.example.com/p", panelToken: "t", panelSession: "c", panelCSRF: "x")
        #expect(settings.panelCredential == .bearer("t"))
    }

    @Test func headerValidation() {
        #expect(CustomHeader(name: "CF-Access-Client-Id", value: "abc.access").validationError == nil)
        #expect(CustomHeader(name: "", value: "x").validationError != nil)
        #expect(CustomHeader(name: "Bad Name", value: "x").validationError != nil)
        #expect(CustomHeader(name: "X-Thing", value: "").validationError != nil)
        #expect(CustomHeader(name: "X-Thing", value: "a\nb").validationError != nil)
        for reserved in ["Authorization", "cookie", "Host", "Content-Type", "X-CSRF-Token", "x-requested-with"] {
            #expect(CustomHeader(name: reserved, value: "x").validationError != nil)
        }
    }

    @Test func settingsReportTheFirstBadHeader() {
        var settings = ConnectionSettings(panelHeaders: [CustomHeader(name: "X-Ok", value: "1"), CustomHeader(name: "Cookie", value: "x")])
        #expect(settings.headerError != nil)
        settings.panelHeaders = [CustomHeader(name: "X-Ok", value: "1"), CustomHeader(name: "", value: "")]
        #expect(settings.headerError == nil)
        #expect(settings.normalized().panelHeaders.count == 1)
    }

    @Test func everyPanelRequestCarriesTheCustomHeadersButCannotLoseTheCredential() async throws {
        let transport = FakeTransport(.ok(#"{"cpu": 1}"#))
        let settings = ConnectionSettings(
            panelURL: "https://vpn.example.com:8443/p", panelToken: "tok",
            panelHeaders: [
                CustomHeader(name: "CF-Access-Client-Id", value: "id.access"),
                CustomHeader(name: "CF-Access-Client-Secret", value: "secret"),
                CustomHeader(name: "Authorization", value: "Bearer evil"),
            ]
        )
        let client = try #require(PanelClient(settings: settings, transport: transport))
        _ = try await client.serverStatus()
        let request = transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func aSessionRequestCarriesTheCookieAndTheCSRFToken() async throws {
        let transport = FakeTransport(.ok(#"{"cpu": 1}"#))
        let settings = ConnectionSettings(panelURL: "https://vpn.example.com:8443/p", panelSession: "cookie-1", panelCSRF: "csrf-1")
        let client = try #require(PanelClient(settings: settings, transport: transport))
        _ = try await client.serverStatus()
        let request = transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "Cookie") == "3x-ui=cookie-1")
        #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-1")
        #expect(request.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func noClientWithoutACredential() {
        #expect(PanelClient(settings: ConnectionSettings(panelURL: "https://vpn.example.com/p")) == nil)
        #expect(PanelClient(settings: ConnectionSettings(panelToken: "t")) == nil)
    }
}
