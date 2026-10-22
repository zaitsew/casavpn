import Foundation
import Testing
@testable import CasaKit

@Suite("RelayClient")
struct RelayClientTests {
    func client(_ transport: FakeTransport) -> RelayClient {
        RelayClient(baseURL: relayURL, token: "app-token", transport: transport)
    }

    @Test func registerDeviceRequest() throws {
        let c = client(FakeTransport())
        let reg = DeviceRegistration(token: "ab12cd", environment: .sandbox, name: "Test iPhone")
        let r = try c.makeRequest(.registerDevice(reg))
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://casavpn-monitor.example.workers.dev/v1/devices")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer app-token")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(r.bodyText == #"{"environment":"sandbox","name":"Test iPhone","token":"ab12cd"}"#)
    }

    @Test func deviceNameIsCutToFortyCharacters() {
        let reg = DeviceRegistration(token: "ab", environment: .production, name: String(repeating: "x", count: 80))
        #expect(reg.name.count == 40)
    }

    @Test func deleteDeviceRequest() throws {
        let r = try client(FakeTransport()).makeRequest(.deleteDevice(token: "ab12cd"))
        #expect(r.httpMethod == "DELETE")
        #expect(r.url?.path == "/v1/devices/ab12cd")
        #expect(r.httpBody == nil)
    }

    @Test func nonHexTokensAreRefusedBeforeAnythingIsSent() {
        let c = client(FakeTransport())
        #expect(throws: RelayError.self) { try c.makeRequest(.deleteDevice(token: "../x")) }
        #expect(throws: RelayError.self) { try c.makeRequest(.registerDevice(DeviceRegistration(token: "", environment: .sandbox, name: "n"))) }
    }

    @Test func alertsRequestClampsTheLimit() throws {
        let c = client(FakeTransport())
        #expect(try c.makeRequest(.alerts(limit: 50)).url?.query == "limit=50")
        #expect(try c.makeRequest(.alerts(limit: 0)).url?.query == "limit=1")
        #expect(try c.makeRequest(.alerts(limit: 500)).url?.query == "limit=100")
    }

    @Test func baseURLWithATrailingSlashDoesNotDoubleIt() throws {
        let c = RelayClient(baseURL: URL(string: "https://r.example.com/")!, token: "t", transport: FakeTransport())
        #expect(try c.makeRequest(.test).url?.absoluteString == "https://r.example.com/v1/test")
    }

    @Test func decodesAlertsAndMonitorFromTheContract() async throws {
        let json = """
        {"alerts": [
          {"id": "0001", "kind": "vpn.down", "severity": "critical", "title": "VPN is down",
           "body": "Port 443 does not answer", "at": "2026-10-22T08:15:30.123Z", "source": "monitor"},
          {"id": "0000", "kind": "test", "severity": "info", "title": "Test", "body": "Hello",
           "at": "2026-10-22T08:00:00Z", "source": "app"}],
         "monitor": {"status": "down", "since": "2026-10-22T08:15:30Z", "lastCheck": "2026-10-22T08:20:00Z",
                     "ip": "203.0.113.7", "target": "vpn.example.com:443"}}
        """
        let transport = FakeTransport(.response(status: 200, body: json))
        let result = try await client(transport).alerts(limit: 20)
        #expect(result.alerts.count == 2)
        #expect(result.alerts[0].id == "0001")
        #expect(result.alerts[0].severity == .critical)
        #expect(result.alerts[0].group == "vpn")
        #expect(result.alerts[1].severity == .info)
        #expect(result.alerts[0].at.timeIntervalSince1970 == 1_792_656_930.123)
        #expect(result.monitor?.status == .down)
        #expect(result.monitor?.ip == "203.0.113.7")
        #expect(result.monitor?.target == "vpn.example.com:443")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer app-token")
    }

    @Test func monitorToleratesNullIPAndMissingDates() async throws {
        let json = #"{"alerts": [], "monitor": {"status": "unknown", "ip": null, "target": "vpn.example.com:443"}}"#
        let result = try await client(FakeTransport(.response(status: 200, body: json))).alerts()
        #expect(result.monitor?.status == .unknown)
        #expect(result.monitor?.ip == nil)
        #expect(result.monitor?.since == nil)
    }

    @Test func unknownSeverityFallsBackToInfo() async throws {
        let json = #"{"alerts": [{"id": "1", "kind": "x", "severity": "fatal", "title": "t", "body": "b", "at": "2026-10-22T08:00:00Z", "source": "host"}]}"#
        let result = try await client(FakeTransport(.response(status: 200, body: json))).alerts()
        #expect(result.alerts[0].severity == .info)
        #expect(result.monitor == nil)
    }

    @Test func decodesThePushResult() async throws {
        let transport = FakeTransport(.response(status: 202, body: #"{"id": "abc", "pushed": 2}"#))
        let result = try await client(transport).sendTest()
        #expect(result.pushed == 2)
        #expect(result.id == "abc")
    }

    @Test func registerAcceptsNoContent() async throws {
        let transport = FakeTransport(.response(status: 204, body: ""))
        try await client(transport).registerDevice(DeviceRegistration(token: "ab", environment: .production, name: "n"))
        #expect(transport.requests.count == 1)
    }

    @Test func wrongTokenIs401WithNoBody() async {
        do {
            _ = try await client(FakeTransport(.response(status: 401, body: ""))).alerts()
            Issue.record("expected an error")
        } catch {
            #expect(error as? RelayError == .unauthorized)
            #expect((error as? RelayError)?.kind == .unauthorized)
        }
    }

    @Test func networkFailureIsUnreachable() async {
        do {
            _ = try await client(FakeTransport(.failure(.timedOut))).alerts()
            Issue.record("expected an error")
        } catch {
            #expect(error as? RelayError == .unreachable)
        }
    }

    @Test func garbageIsADecodingError() async {
        do {
            _ = try await client(FakeTransport(.response(status: 200, body: "<html>"))).alerts()
            Issue.record("expected an error")
        } catch {
            #expect(error as? RelayError == .decoding)
        }
    }

    @Test func otherStatusesCarryTheCode() async {
        do {
            _ = try await client(FakeTransport(.response(status: 500, body: ""))).sendTest()
            Issue.record("expected an error")
        } catch {
            #expect(error as? RelayError == .http(500))
        }
    }
}

@Suite("DeviceToken")
struct DeviceTokenTests {
    @Test func hexIsLowercaseAndZeroPadded() {
        #expect(DeviceToken.hex(Data([0x00, 0x0a, 0xff, 0x10])) == "000aff10")
        #expect(DeviceToken.hex(Data()) == "")
    }

    @Test func hexOfThirtyTwoBytesIsSixtyFourCharacters() {
        let token = DeviceToken.hex(Data((0..<32).map { UInt8($0 * 8) }))
        #expect(token.count == 64)
        #expect(DeviceToken.isHex(token))
    }

    @Test func isHexRejectsOtherText() {
        #expect(!DeviceToken.isHex(""))
        #expect(!DeviceToken.isHex("xyz"))
        #expect(!DeviceToken.isHex("ab/cd"))
    }
}
