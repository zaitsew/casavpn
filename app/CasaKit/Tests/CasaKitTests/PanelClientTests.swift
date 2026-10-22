import Foundation
import Testing
@testable import CasaKit

// Sample answers copied in shape from 3x-ui v3.10.2 (see PanelModels.swift for the source files).
enum Sample {
    static let status = """
    {"success": true, "msg": "", "obj": {
      "cpu": 12.5, "cpuCores": 4, "logicalPro": 4, "cpuSpeedMhz": 2400,
      "mem": {"current": 1073741824, "total": 4294967296},
      "swap": {"current": 0, "total": 2147483648},
      "disk": {"current": 8589934592, "total": 31914983424},
      "diskIO": {"read": 0, "write": 0}, "diskTraffic": {"read": 0, "write": 0},
      "xray": {"state": "running", "errorMsg": "", "version": "26.7.28"},
      "amneziawg": {"configured": false, "running": false},
      "panelVersion": "3.10.2", "panelGuid": "g", "uptime": 987654, "loads": [0.12, 0.2, 0.18],
      "tcpCount": 41, "udpCount": 9,
      "netIO": {"up": 1, "down": 2, "pktUp": 3, "pktDown": 4},
      "netTraffic": {"sent": 5, "recv": 6, "pktSent": 7, "pktRecv": 8},
      "publicIP": {"ipv4": "203.0.113.7", "ipv6": "N/A"},
      "appStats": {"threads": 12, "mem": 1000, "uptime": 99}}}
    """

    static let clients = """
    {"success": true, "msg": "", "obj": {
      "items": [
        {"email": "alice", "subId": "sub-alice", "enable": true, "totalGB": 53687091200,
         "expiryTime": 1793000000000, "limitIp": 0, "limitHwid": 0, "reset": 0, "resetDay": 0,
         "resetWeekday": 0, "resetMax": 0, "group": "family", "comment": "Phone", "inboundIds": [1],
         "traffic": {"id": 1, "inboundId": 1, "enable": true, "email": "alice", "up": 1073741824,
                     "down": 2147483648, "expiryTime": 1793000000000, "total": 53687091200,
                     "reset": 0, "lastOnline": 1792600000000, "lastSubFetch": 0},
         "createdAt": 1, "updatedAt": 2},
        {"email": "bob", "subId": "sub-bob", "enable": false, "totalGB": 0, "expiryTime": 0,
         "limitIp": 0, "limitHwid": 0, "reset": 0, "resetDay": 0, "resetWeekday": 0, "resetMax": 0,
         "inboundIds": [1], "createdAt": 1, "updatedAt": 2}],
      "total": 2, "filtered": 2, "page": 1, "pageSize": 200,
      "summary": {"total": 2, "active": 1, "onlineCount": 1, "depletedCount": 0, "expiringCount": 0,
                  "deactiveCount": 1, "online": ["alice"], "depleted": null, "expiring": null, "deactive": ["bob"]},
      "groups": ["family"]}}
    """

    static let record = """
    {"success": true, "msg": "", "obj": {
      "client": {"id": 7, "email": "alice", "subId": "sub-alice", "uuid": "test-client-uuid",
                 "password": "", "auth": "", "flow": "xtls-rprx-vision", "security": "auto", "reverse": null,
                 "limitIp": 2, "limitHwid": 0, "totalGB": 53687091200, "expiryTime": 1793000000000,
                 "enable": true, "tgId": 0, "group": "family", "comment": "Phone", "reset": 0, "resetDay": 0,
                 "resetWeekday": 0, "resetMax": 0, "trafficReset": "never", "trafficResetDay": 1,
                 "createdAt": 1, "updatedAt": 2},
      "inboundIds": [1], "externalLinks": [], "usedTraffic": 3221225472, "tunnelAllowedIPs": {}}}
    """
}

@Suite("PanelClient")
struct PanelClientTests {
    func client(_ transport: FakeTransport, token: String = "panel-token") -> PanelClient {
        PanelClient(baseURL: panelURL, token: token, transport: transport)
    }

    @Test func statusRequestGoesUnderTheBasePath() throws {
        let r = try client(FakeTransport()).makeRequest(route: ["server", "status"])
        #expect(r.httpMethod == "GET")
        #expect(r.url?.absoluteString == "https://vpn.example.com:8443/secret-path/panel/api/server/status")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer panel-token")
    }

    @Test func emailsAreEncodedAsOnePathSegment() throws {
        let r = try client(FakeTransport()).makeRequest(route: ["clients", "get", "a b/c@example.com"])
        #expect(r.url?.absoluteString.hasSuffix("/panel/api/clients/get/a%20b%2Fc@example.com") == true)
    }

    @Test func decodesTheServerStatus() async throws {
        let s = try await client(FakeTransport(.response(status: 200, body: Sample.status))).serverStatus()
        #expect(s.xray.state == .running)
        #expect(s.xray.version == "26.7.28")
        #expect(s.cpu == 12.5)
        #expect(s.mem.current == 1_073_741_824)
        #expect(s.mem.fraction == 0.25)
        #expect(s.disk.total == 31_914_983_424)
        #expect(s.uptime == 987_654)
        #expect(s.loads == [0.12, 0.2, 0.18])
        #expect(s.publicIPv4 == "203.0.113.7")
        #expect(s.panelVersion == "3.10.2")
    }

    @Test func statusToleratesMissingFieldsAndUnknownStates() async throws {
        let body = #"{"success": true, "obj": {"cpu": 1, "xray": {"state": "starting"}}}"#
        let s = try await client(FakeTransport(.response(status: 200, body: body))).serverStatus()
        #expect(s.xray.state == .unknown)
        #expect(s.mem == ServerStatus.Usage())
        #expect(s.publicIPv4 == nil)
    }

    @Test func clientsRequestAsksForTheBiggestPage() async throws {
        let transport = FakeTransport(.response(status: 200, body: Sample.clients))
        _ = try await client(transport).clients()
        // The list, then the live "online" answer.
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].url?.path == "/secret-path/panel/api/clients/onlines")
        #expect(transport.requests[1].httpMethod == "POST")
        #expect(transport.requests[0].url?.path == "/secret-path/panel/api/clients/list/paged")
        #expect(transport.requests[0].url?.query == "page=1&pageSize=200")
    }

    @Test func decodesClientsAndWhoIsOnline() async throws {
        let snapshot = try await client(FakeTransport(.response(status: 200, body: Sample.clients))).clients()
        #expect(snapshot.clients.map(\.email) == ["alice", "bob"])
        let alice = snapshot.clients[0]
        #expect(alice.enable)
        #expect(alice.usedBytes == 3_221_225_472)
        #expect(alice.limitBytes == 53_687_091_200)
        #expect(alice.subId == "sub-alice")
        #expect(alice.group == "family")
        let bob = snapshot.clients[1]
        #expect(!bob.enable)
        #expect(bob.limitBytes == nil)
        #expect(bob.usedBytes == 0)
        #expect(snapshot.online == ["alice"])
    }

    @Test func readsFurtherPagesUntilTheTotalIsReached() async throws {
        func page(_ emails: [String], total: Int) -> String {
            let items = emails.map { #"{"email": "\#($0)", "subId": "s", "enable": true, "totalGB": 0, "expiryTime": 0}"# }
            return #"{"success": true, "obj": {"items": [\#(items.joined(separator: ","))], "total": \#(total), "summary": {"online": ["a"]}}}"#
        }
        let transport = FakeTransport(.response(status: 200, body: page(["a", "b"], total: 3)), .response(status: 200, body: page(["c"], total: 3)))
        let snapshot = try await client(transport).clients()
        #expect(snapshot.clients.map(\.email) == ["a", "b", "c"])
        #expect(transport.requests.prefix(2).map { $0.url?.query } == ["page=1&pageSize=200", "page=2&pageSize=200"])
    }

    @Test func readsMoreThanTwentyFivePages() async throws {
        let total = 40
        let replies = (1...total).map { n in
            FakeTransport.Reply.response(status: 200, body: #"{"success": true, "obj": {"items": [{"email": "c\#(n)", "subId": "s", "enable": true}], "total": \#(total), "summary": {"online": []}}}"#)
        }
        let transport = FakeTransport(replies)
        let snapshot = try await client(transport).clients()
        #expect(snapshot.clients.count == total)
        #expect(transport.requests.count == total + 1)
    }

    @Test func hittingTheSafetyCapIsAnErrorNotAPartialList() async {
        let replies = (1...5).map { n in
            FakeTransport.Reply.response(status: 200, body: #"{"success": true, "obj": {"items": [{"email": "c\#(n)"}], "total": 100, "summary": {}}}"#)
        }
        let capped = PanelClient(baseURL: panelURL, token: "t", transport: FakeTransport(replies), maxPages: 3)
        do {
            _ = try await capped.clients()
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .incompleteList)
        }
    }

    @Test func nullListsFromGoDecodeAsEmpty() async throws {
        let body = #"{"success": true, "obj": {"items": null, "total": 0, "summary": {"online": null}}}"#
        let snapshot = try await client(FakeTransport(.response(status: 200, body: body))).clients()
        #expect(snapshot.clients.isEmpty)
        #expect(snapshot.online.isEmpty)
    }

    @Test func aMonitorTokenGets403OnTheClientRoutes() async {
        let body = #"{"success": false, "msg": "this API token is not permitted to access this endpoint"}"#
        do {
            _ = try await client(FakeTransport(.response(status: 403, body: body))).clients()
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .forbidden("this API token is not permitted to access this endpoint"))
            #expect((error as? PanelError)?.errorDescription == PanelMessages.forbidden("this API token is not permitted to access this endpoint"))
        }
    }

    @Test func aBadTokenIs401() async {
        do {
            _ = try await client(FakeTransport(.response(status: 401, body: ""))).serverStatus()
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .unauthorized)
        }
    }

    @Test func aClosedPanelIsUnreachableWithTheContractSentence() async {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .notConnectedToInternet, .cannotFindHost] {
            do {
                _ = try await client(FakeTransport(.failure(code))).serverStatus()
                Issue.record("expected an error")
            } catch {
                #expect(error as? PanelError == .unreachable)
                #expect((error as? PanelError)?.errorDescription == "The panel answers only on the home network, over the VPN or over Tailscale.")
            }
        }
    }

    @Test func aWrongBasePathIs404() async {
        do {
            _ = try await client(FakeTransport(.response(status: 404, body: ""))).serverStatus()
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .notFound)
        }
    }

    @Test func successFalseCarriesThePanelMessage() async {
        let body = #"{"success": false, "msg": "Something went wrong (Duplicate email)", "obj": null}"#
        do {
            _ = try await client(FakeTransport(.response(status: 200, body: body))).serverStatus()
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .api("Something went wrong (Duplicate email)"))
        }
    }

    @Test func updateBodyRepeatsTheRecordAndChangesOnlyEnable() async throws {
        let transport = FakeTransport(
            .response(status: 200, body: Sample.record),
            .response(status: 200, body: #"{"success": true, "msg": "Client updated", "obj": null}"#)
        )
        try await client(transport).setClientEnabled(email: "alice", enabled: false)

        #expect(transport.requests.count == 2)
        let get = transport.requests[0]
        #expect(get.httpMethod == "GET")
        #expect(get.url?.path == "/secret-path/panel/api/clients/get/alice")

        let post = transport.requests[1]
        #expect(post.httpMethod == "POST")
        #expect(post.url?.path == "/secret-path/panel/api/clients/update/alice")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let sent = try #require(try JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as? [String: Any])
        #expect(sent["enable"] as? Bool == false)
        #expect(sent["email"] as? String == "alice")
        #expect(sent["subId"] as? String == "sub-alice")
        #expect(sent["totalGB"] as? Int == 53_687_091_200)
        #expect(sent["expiryTime"] as? Int == 1_793_000_000_000)
        #expect(sent["limitIp"] as? Int == 2)
        #expect(sent["flow"] as? String == "xtls-rprx-vision")
        #expect(sent["trafficReset"] as? String == "never")
        #expect(sent["comment"] as? String == "Phone")
        // Credentials stay on the panel: it keeps the stored ones when these are absent.
        for key in ["id", "uuid", "password", "auth", "secret", "keepAlive"] {
            #expect(sent[key] == nil)
        }
    }

    @Test func aFailedUpdateIsReported() async {
        let transport = FakeTransport(
            .response(status: 200, body: Sample.record),
            .response(status: 200, body: #"{"success": false, "msg": "nope"}"#)
        )
        do {
            try await client(transport).setClientEnabled(email: "alice", enabled: true)
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .api("nope"))
        }
    }

    @Test func nothingIsUpdatedWhenTheRecordCannotBeRead() async {
        let transport = FakeTransport(.response(status: 403, body: #"{"success": false, "msg": "no"}"#))
        do {
            try await client(transport).setClientEnabled(email: "alice", enabled: true)
            Issue.record("expected an error")
        } catch {
            #expect(transport.requests.count == 1)
        }
    }
}
