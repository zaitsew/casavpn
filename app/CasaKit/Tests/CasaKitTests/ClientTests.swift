import Foundation
import Testing
@testable import CasaKit

@Suite("Clients")
struct ClientTests {
    func panel(_ transport: FakeTransport) -> PanelClient {
        PanelClient(baseURL: panelURL, token: "t", transport: transport)
    }

    // MARK: Draft

    @Test func nameRulesMatchThePanel() {
        var draft = ClientDraft(email: "Laptop", inboundIds: [1])
        #expect(draft.validationError == nil)
        for bad in ["", "   ", "a b", "a/b", "a\\b", "a\tb", "a\nb"] {
            draft.email = bad
            #expect(draft.validationError != nil, "\(bad.debugDescription) should be refused")
        }
        draft.email = String(repeating: "a", count: 65)
        #expect(draft.validationError != nil)
        draft.email = "Work-Laptop"
        #expect(draft.validationError == nil)
    }

    @Test func limitsAndInboundsAreChecked() {
        var draft = ClientDraft(email: "Phone", inboundIds: [1])
        draft.totalGB = -1
        #expect(draft.validationError != nil)
        draft.totalGB = 10; draft.limitIp = -1
        #expect(draft.validationError != nil)
        draft.limitIp = 2; draft.subId = "has space"
        #expect(draft.validationError != nil)
        draft.subId = ""; draft.inboundIds = []
        #expect(draft.validationError == "Pick at least one inbound.")
        // An existing client keeps its inbounds, so none are needed.
        draft.originalEmail = "Phone"
        #expect(draft.validationError == nil)
        draft.expiry = .afterFirstUse(days: 0)
        #expect(draft.validationError != nil)
    }

    @Test func gigabytesBecomeBytes() {
        #expect(ClientDraft(email: "a", totalGB: 50).totalBytes == 53_687_091_200)
        #expect(ClientDraft(email: "a", totalGB: 0).totalBytes == 0)
        #expect(ClientDraft(email: "a", totalGB: 1.5).totalBytes == 1_610_612_736)
    }

    @Test func expiryIsStoredAsThePanelStoresIt() {
        #expect(ClientExpiry.never.milliseconds == 0)
        #expect(ClientExpiry.afterFirstUse(days: 30).milliseconds == -2_592_000_000)
        #expect(ClientExpiry.date(Date(timeIntervalSince1970: 1_793_000_000)).milliseconds == 1_793_000_000_000)
        #expect(ClientExpiry(expiryTime: 0) == .never)
        #expect(ClientExpiry(expiryTime: -2_592_000_000) == .afterFirstUse(days: 30))
        #expect(ClientExpiry(expiryTime: 1_793_000_000_000) == .date(Date(timeIntervalSince1970: 1_793_000_000)))
        let day = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 9))!
        let end = ClientExpiry.endOfDay(day, calendar: Calendar(identifier: .gregorian))
        #expect(Calendar(identifier: .gregorian).component(.hour, from: end) == 23)
        #expect(Calendar(identifier: .gregorian).component(.day, from: end) == 31)
    }

    @Test func randomSubIdsLookLikeThePanelsOwn() {
        let id = ClientDraft.randomSubId()
        #expect(id.count == 16)
        #expect(id.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil)
        #expect(id != ClientDraft.randomSubId())
    }

    // MARK: Routes

    @Test func addingAClientSendsTheCreatePayload() async throws {
        let transport = FakeTransport(.ok())
        var draft = ClientDraft(email: " Tablet ", totalGB: 100, expiry: .afterFirstUse(days: 30), limitIp: 2, comment: "Kids", inboundIds: [1, 2], flow: "xtls-rprx-vision")
        draft.subId = ""
        try await panel(transport).saveClient(draft)
        let request = transport.requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.path == "/secret-path/panel/api/clients/add")
        let body = request.jsonBody
        #expect(body["inboundIds"] as? [Int] == [1, 2])
        let client = try #require(body["client"] as? [String: Any])
        #expect(client["email"] as? String == "Tablet")
        #expect(client["totalGB"] as? Int == 107_374_182_400)
        #expect(client["expiryTime"] as? Int == -2_592_000_000)
        #expect(client["limitIp"] as? Int == 2)
        #expect(client["flow"] as? String == "xtls-rprx-vision")
        #expect(client["enable"] as? Bool == true)
        #expect(client["comment"] as? String == "Kids")
        #expect((client["subId"] as? String)?.count == 16)
        for key in ["id", "password", "auth", "uuid"] { #expect(client[key] == nil) }
    }

    @Test func editingAClientRepeatsTheStoredRecordAndChangesTheFormFields() async throws {
        let transport = FakeTransport(.response(status: 200, body: Sample.record), .ok())
        let current = try await panel(FakeTransport(.response(status: 200, body: Sample.record))).client(email: "alice")
        var draft = ClientDraft(editing: current)
        #expect(draft.originalEmail == "alice")
        #expect(draft.totalGB == 50)
        draft.totalGB = 80
        draft.expiry = .never
        draft.limitIp = 5
        draft.enable = false
        draft.comment = "Spare phone"
        try await panel(transport).saveClient(draft)

        #expect(transport.requests.map(\.path) == ["/secret-path/panel/api/clients/get/alice", "/secret-path/panel/api/clients/update/alice"])
        let sent = transport.requests[1].jsonBody
        #expect(sent["totalGB"] as? Int == 85_899_345_920)
        #expect(sent["expiryTime"] as? Int == 0)
        #expect(sent["limitIp"] as? Int == 5)
        #expect(sent["enable"] as? Bool == false)
        #expect(sent["comment"] as? String == "Spare phone")
        // Unchanged fields come back as stored; credentials stay on the panel.
        #expect(sent["subId"] as? String == "sub-alice")
        #expect(sent["flow"] as? String == "xtls-rprx-vision")
        #expect(sent["group"] as? String == "family")
        for key in ["id", "uuid", "password", "auth"] { #expect(sent[key] == nil) }
    }

    @Test func readsAClientInFull() async throws {
        let detail = try await panel(FakeTransport(.response(status: 200, body: Sample.record))).client(email: "alice")
        #expect(detail.email == "alice")
        #expect(detail.uuid == "test-client-uuid")
        #expect(detail.inboundIds == [1])
        #expect(detail.usedBytes == 3_221_225_472)
        #expect(detail.limitIp == 2)
        #expect(detail.flow == "xtls-rprx-vision")
    }

    @Test func resetDeleteAndLinksUseTheirRoutes() async throws {
        let transport = FakeTransport(.ok(), .ok(), .ok(#"["vless://00000000-0000-4000-8000-000000000001@demo.example.com:443?type=tcp#Home"]"#))
        let api = panel(transport)
        try await api.resetClientTraffic(email: "a b")
        try await api.deleteClient(email: "alice")
        let links = try await api.clientLinks(email: "alice")
        #expect(links.count == 1)
        #expect(transport.requests.map(\.path) == [
            "/secret-path/panel/api/clients/resetTraffic/a b", "/secret-path/panel/api/clients/del/alice",
            "/secret-path/panel/api/clients/links/alice",
        ])
        #expect(transport.requests.map(\.httpMethod) == ["POST", "POST", "GET"])
        #expect(transport.requests[0].url?.absoluteString.hasSuffix("/resetTraffic/a%20b") == true)
    }

    @Test func noLinksIsAnEmptyList() async throws {
        #expect(try await panel(FakeTransport(.ok("null"))).clientLinks(email: "x").isEmpty)
    }

    @Test func onlineNowIsTheUnionOfTheListAndTheOnlinesRoute() async throws {
        let transport = FakeTransport(.response(status: 200, body: Sample.clients), .ok(#"["bob"]"#))
        let snapshot = try await panel(transport).clients()
        #expect(snapshot.online == ["alice", "bob"])
    }

    @Test func aFailingOnlinesRouteDoesNotFailTheList() async throws {
        let transport = FakeTransport(.response(status: 200, body: Sample.clients), .response(status: 500, body: ""))
        let snapshot = try await panel(transport).clients()
        #expect(snapshot.online == ["alice"])
        #expect(snapshot.clients.count == 2)
    }

    @Test func theListCarriesInboundsAndLastOnline() async throws {
        let snapshot = try await panel(FakeTransport(.response(status: 200, body: Sample.clients))).clients()
        let alice = snapshot.clients[0]
        #expect(alice.inboundIds == [1])
        #expect(alice.traffic?.lastOnline == 1_792_600_000_000)
        #expect(alice.traffic?.email == "alice")
    }

    @Test func subscriptionBaseComesFromTheDefaultSettings() async throws {
        let on = FakeTransport(.ok(#"{"subEnable": true, "subURI": "https://vpn.example.com:2096/sub/", "pageSize": 25}"#))
        #expect(try await panel(on).subscriptionBase() == "https://vpn.example.com:2096/sub/")
        #expect(on.requests[0].path == "/secret-path/panel/api/setting/defaultSettings")
        #expect(on.requests[0].httpMethod == "POST")
        let off = FakeTransport(.ok(#"{"subEnable": false, "subURI": ""}"#))
        #expect(try await panel(off).subscriptionBase() == nil)
    }

    @Test func invalidDraftsAreRefusedBeforeTheNetwork() async {
        let transport = FakeTransport()
        do {
            try await panel(transport).saveClient(ClientDraft(email: "bad name", inboundIds: [1]))
            Issue.record("expected an error")
        } catch {
            #expect(error is PanelError)
        }
        #expect(transport.requests.isEmpty)
    }
}

@Suite("Logs and Xray control")
struct LogTests {
    func panel(_ transport: FakeTransport) -> PanelClient {
        PanelClient(baseURL: panelURL, token: "t", transport: transport)
    }

    static let accessLog = """
    [{"DateTime": "2026-10-22T10:15:30Z", "FromAddress": "203.0.113.21:40100", "ToAddress": "api.example.com:443", "Inbound": "inbound-443", "Outbound": "direct", "Email": "Phone", "Event": 0},
     {"DateTime": "0001-01-01T00:00:00Z", "FromAddress": "203.0.113.34:40200", "ToAddress": "cdn.example.org:443", "Inbound": "inbound-443", "Outbound": "blocked", "Email": "", "Event": 1},
     {"DateTime": "2026-10-22T10:16:00.250Z", "FromAddress": "203.0.113.55:40300", "ToAddress": "chat.example.org:443", "Inbound": "", "Outbound": "proxy", "Email": "Laptop", "Event": 2}]
    """

    @Test func xrayLogRequestIsAFormWithTheFilter() async throws {
        let transport = FakeTransport(.ok(Self.accessLog))
        let entries = try await panel(transport).xrayLog(count: 200, filter: "Phone & co")
        let request = transport.requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.path == "/secret-path/panel/api/server/xraylogs/200")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.bodyText == "filter=Phone%20%26%20co&showDirect=true&showBlocked=true&showProxy=true")
        #expect(entries.count == 3)
        #expect(entries[0].email == "Phone")
        #expect(entries[0].event == .direct)
        #expect(entries[0].date != nil)
        #expect(entries[1].event == .blocked)
        #expect(entries[1].date == nil)
        #expect(entries[2].event == .proxied)
        #expect(entries[2].date != nil)
        #expect(entries[0].line.contains("203.0.113.21:40100"))
        #expect(entries[0].line.contains("api.example.com:443"))
    }

    @Test func anEmptyLogIsAnEmptyList() async throws {
        #expect(try await panel(FakeTransport(.ok("null"))).xrayLog(count: 50, filter: "").isEmpty)
    }

    @Test func theCountIsKeptInRange() async throws {
        let transport = FakeTransport(.ok("[]"), .ok("[]"))
        _ = try await panel(transport).xrayLog(count: 0, filter: "")
        _ = try await panel(transport).xrayLog(count: 50_000, filter: "")
        #expect(transport.requests.map(\.path) == ["/secret-path/panel/api/server/xraylogs/1", "/secret-path/panel/api/server/xraylogs/1000"])
    }

    @Test func panelLogReturnsLines() async throws {
        let transport = FakeTransport(.ok(#"["2026/10/22 10:00:00 INFO - Xray started", "2026/10/22 10:01:00 WARNING - slow"]"#))
        let lines = try await panel(transport).panelLog(count: 100, level: "info")
        #expect(lines.count == 2)
        #expect(transport.requests[0].path == "/secret-path/panel/api/server/logs/100")
        #expect(transport.requests[0].bodyText == "level=info&syslog=false")
    }

    @Test func restartAndStopAreConfirmedPosts() async throws {
        let transport = FakeTransport(.ok(), .ok())
        try await panel(transport).restartXray()
        try await panel(transport).stopXray()
        #expect(transport.requests.map(\.path) == ["/secret-path/panel/api/server/restartXrayService", "/secret-path/panel/api/server/stopXrayService"])
        #expect(transport.requests.allSatisfy { $0.httpMethod == "POST" })
    }

    @Test func aRefusedRestartCarriesThePanelMessage() async {
        do {
            try await panel(FakeTransport(.refused("Xray failed to start: bad config"))).restartXray()
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .api("Xray failed to start: bad config"))
        }
    }

    @Test func statusCarriesNetworkSpeedAndTotals() async throws {
        let s = try await panel(FakeTransport(.response(status: 200, body: Sample.status))).serverStatus()
        #expect(s.netUp == 1 && s.netDown == 2)
        #expect(s.netSent == 5 && s.netReceived == 6)
        #expect(s.udpCount == 9)
        #expect(s.swap.total == 2_147_483_648)
    }
}
