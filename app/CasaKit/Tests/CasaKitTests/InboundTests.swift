import Foundation
import Testing
@testable import CasaKit

// Fixtures are shaped like model.Inbound of 3x-ui v3.10.2: `settings`, `streamSettings` and `sniffing`
// are nested objects in the modern shape and JSON strings in the legacy one (Inbound.MarshalJSON).
enum InboundSample {
    static let realityStream = """
    {"network": "tcp", "security": "reality", "externalProxy": [],
     "realitySettings": {"show": false, "xver": 0, "target": "www.example.com:443", "serverNames": ["www.example.com"],
       "privateKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "minClientVer": "", "maxClientVer": "",
       "maxTimediff": 0, "shortIds": ["a1b2c3d4", "e5f60718"], "mldsa65Seed": "",
       "settings": {"publicKey": "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A", "fingerprint": "firefox", "serverName": "", "spiderX": "/", "mldsa65Verify": ""}},
     "tcpSettings": {"acceptProxyProtocol": false, "header": {"type": "none"}},
     "sockopt": {"tcpFastOpen": true}}
    """

    static let settings = """
    {"clients": [{"email": "Laptop", "id": "00000000-0000-4000-8000-000000000001", "flow": "xtls-rprx-vision", "enable": true},
                 {"email": "Phone", "id": "00000000-0000-4000-8000-000000000002", "flow": "xtls-rprx-vision", "enable": true}],
     "decryption": "none", "encryption": "none", "fallbacks": []}
    """

    static func inboundJSON(nested: Bool) -> String {
        func field(_ text: String) -> String {
            nested ? text : "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
        }
        return """
        {"id": 1, "userId": 1, "up": 1073741824, "down": 3221225472, "total": 0, "allTime": 0, "remark": "Home Reality",
         "enable": true, "expiryTime": 0, "listen": "", "port": 443, "protocol": "vless", "tag": "inbound-443",
         "disableFlow": false, "trafficReset": "never", "lastTrafficResetTime": 0,
         "settings": \(field(settings)), "streamSettings": \(field(realityStream)),
         "sniffing": \(field(#"{"enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false, "routeOnly": false}"#)),
         "clientStats": [{"id": 1, "inboundId": 1, "enable": true, "email": "Laptop", "up": 100, "down": 200, "total": 0, "expiryTime": 0, "lastOnline": 0},
                         {"id": 2, "inboundId": 1, "enable": true, "email": "Phone", "up": 5, "down": 6, "total": 1000, "expiryTime": 0, "lastOnline": 1792600000000}]}
        """
    }

    static func listBody(nested: Bool = true) -> String { #"{"success": true, "msg": "", "obj": [\#(inboundJSON(nested: nested))]}"# }
    static func getBody(nested: Bool = true) -> String { #"{"success": true, "msg": "", "obj": \#(inboundJSON(nested: nested))}"# }
}

@Suite("Inbounds")
struct InboundTests {
    func client(_ transport: FakeTransport) -> PanelClient {
        PanelClient(baseURL: panelURL, token: "t", transport: transport)
    }

    @Test(arguments: [true, false]) func decodesAnInboundInBothShapes(nested: Bool) async throws {
        let transport = FakeTransport(.response(status: 200, body: InboundSample.listBody(nested: nested)))
        let list = try await client(transport).inbounds()
        #expect(transport.requests[0].path == "/secret-path/panel/api/inbounds/list/slim")
        let inbound = try #require(list.first)
        #expect(inbound.id == 1)
        #expect(inbound.remark == "Home Reality")
        #expect(inbound.port == 443)
        #expect(inbound.protocolName == "vless")
        #expect(inbound.enable)
        #expect(inbound.up == 1_073_741_824 && inbound.down == 3_221_225_472)
        #expect(inbound.usedBytes == 4_294_967_296)
        #expect(inbound.clientCount == 2)
        #expect(inbound.network == "tcp")
        #expect(inbound.security == "reality")
        #expect(inbound.summary == "VLESS · Reality · TCP")
        #expect(inbound.isEditableReality)
        #expect(inbound.wantsVisionFlow)
        #expect(inbound.clientStats.map(\.email) == ["Laptop", "Phone"])
        #expect(inbound.clientStats[1].lastOnline == 1_792_600_000_000)
        let reality = try #require(inbound.reality)
        #expect(reality.target == "www.example.com:443")
        #expect(reality.serverNames == ["www.example.com"])
        #expect(reality.shortIds == ["a1b2c3d4", "e5f60718"])
        #expect(reality.publicKey == "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A")
        #expect(reality.fingerprint == "firefox")
    }

    @Test func anEmptyListIsAnEmptyListNotAnError() async throws {
        let list = try await client(FakeTransport(.ok("null"))).inbounds()
        #expect(list.isEmpty)
    }

    @Test func otherProtocolsAreReadOnly() throws {
        let data = Data(#"{"id": 2, "remark": "SS", "port": 8388, "protocol": "shadowsocks", "settings": {"method": "x", "clients": []}, "streamSettings": {"network": "tcp", "security": "none"}}"#.utf8)
        let inbound = try JSONDecoder().decode(Inbound.self, from: data)
        #expect(!inbound.isEditableReality)
        #expect(inbound.reality == nil)
        #expect(inbound.summary == "SHADOWSOCKS · TCP")
    }

    @Test func switchesAndResets() async throws {
        let transport = FakeTransport(.ok(), .ok(), .ok(), .ok())
        let panel = client(transport)
        try await panel.setInboundEnabled(id: 4, enabled: false)
        try await panel.resetInboundTraffic(id: 4)
        try await panel.deleteInbound(id: 4)
        try await panel.restartXray()
        #expect(transport.requests.map(\.path) == [
            "/secret-path/panel/api/inbounds/setEnable/4", "/secret-path/panel/api/inbounds/4/resetTraffic",
            "/secret-path/panel/api/inbounds/del/4", "/secret-path/panel/api/server/restartXrayService",
        ])
        #expect(transport.requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(transport.requests[0].jsonBody["enable"] as? Bool == false)
    }

    // MARK: Draft

    @Test func aNewDraftIsValidAndHasShortIds() {
        let draft = RealityInboundDraft.newDraft()
        #expect(draft.validationError == nil)
        #expect(draft.shortIds.count == 2)
        #expect(draft.shortIds.allSatisfy { $0.count == 8 })
        #expect(draft.isNew)
    }

    @Test func draftValidation() {
        var draft = RealityInboundDraft.newDraft()
        draft.remark = " "
        #expect(draft.validationError == "Give the inbound a name.")
        draft = .newDraft(); draft.port = 0
        #expect(draft.validationError?.contains("port") == true)
        draft = .newDraft(); draft.port = 70_000
        #expect(draft.validationError?.contains("port") == true)
        draft = .newDraft(); draft.target = "www.example.com"
        #expect(draft.validationError?.contains("target") == true)
        draft = .newDraft(); draft.target = "bad host:443"
        #expect(draft.validationError?.contains("target") == true)
        draft = .newDraft(); draft.serverNamesText = ""
        #expect(draft.validationError?.contains("server name") == true)
        draft = .newDraft(); draft.shortIdsText = "abc"
        #expect(draft.validationError?.contains("short id") == true)
        draft = .newDraft(); draft.shortIdsText = "zz"
        #expect(draft.validationError?.contains("short id") == true)
        draft = .newDraft(); draft.shortIdsText = "0123456789abcdef01"
        #expect(draft.validationError?.contains("short id") == true)
        draft = .newDraft(); draft.privateKey = "short"
        #expect(draft.validationError?.contains("private key") == true)
        draft = .newDraft(); draft.shortIdsText = "ab, cd12\n01"
        #expect(draft.validationError == nil)
        #expect(draft.shortIds == ["ab", "cd12", "01"])
    }

    @Test func aNewInboundAsksTheKeyPairThenAdds() async throws {
        let transport = FakeTransport(
            .ok(#"{"privateKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "publicKey": "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A"}"#),
            .ok(#"{"id": 7}"#)
        )
        var draft = RealityInboundDraft.newDraft()
        draft.remark = "Travel"; draft.port = 8444; draft.shortIdsText = "a1b2c3d4"
        try await client(transport).saveInbound(draft)

        #expect(transport.requests.map(\.path) == ["/secret-path/panel/api/server/getNewX25519Cert", "/secret-path/panel/api/inbounds/add"])
        let body = transport.requests[1].jsonBody
        #expect(body["protocol"] as? String == "vless")
        #expect(body["remark"] as? String == "Travel")
        #expect(body["port"] as? Int == 8444)
        #expect(body["id"] == nil)
        #expect(body["disableFlow"] as? Bool == false)
        let stream = try #require((body["streamSettings"] as? String).flatMap(JSONDocument.object))
        #expect(stream["security"] as? String == "reality")
        #expect(stream["network"] as? String == "tcp")
        let reality = try #require(stream["realitySettings"] as? [String: Any])
        #expect(reality["target"] as? String == "www.microsoft.com:443")
        #expect(reality["dest"] == nil)
        #expect(reality["serverNames"] as? [String] == ["www.microsoft.com"])
        #expect(reality["shortIds"] as? [String] == ["a1b2c3d4"])
        #expect(reality["privateKey"] as? String == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let inner = try #require(reality["settings"] as? [String: Any])
        #expect(inner["publicKey"] as? String == "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A")
        #expect(inner["fingerprint"] as? String == "chrome")
        let settings = try #require((body["settings"] as? String).flatMap(JSONDocument.object))
        #expect((settings["clients"] as? [Any])?.isEmpty == true)
        #expect(settings["decryption"] as? String == "none")
        #expect(body["sniffing"] is String)
    }

    @Test func aNewInboundWithKeysDoesNotAskForAnotherPair() async throws {
        let transport = FakeTransport(.ok())
        var draft = RealityInboundDraft.newDraft()
        draft.privateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        draft.publicKey = "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A"
        try await client(transport).saveInbound(draft)
        #expect(transport.requests.map(\.path) == ["/secret-path/panel/api/inbounds/add"])
    }

    @Test func anEditSendsBackEverythingItDidNotChange() async throws {
        let transport = FakeTransport(.response(status: 200, body: InboundSample.getBody()), .ok())
        let detail = try await client(FakeTransport(.response(status: 200, body: InboundSample.getBody()))).inbound(id: 1)
        var draft = RealityInboundDraft(editing: detail.inbound)
        #expect(draft.validationError == nil)
        draft.remark = "Home (renamed)"
        draft.port = 8443
        draft.shortIdsText = "a1b2c3d4"
        try await client(transport).saveInbound(draft)

        #expect(transport.requests.map(\.path) == ["/secret-path/panel/api/inbounds/get/1", "/secret-path/panel/api/inbounds/update/1"])
        let body = transport.requests[1].jsonBody
        #expect(body["remark"] as? String == "Home (renamed)")
        #expect(body["port"] as? Int == 8443)
        #expect(body["tag"] as? String == "inbound-443")
        #expect(body["up"] as? Int == 1_073_741_824)
        #expect(body["id"] == nil)
        #expect(body["clientStats"] == nil)
        // The stored client list goes back untouched.
        let settings = try #require((body["settings"] as? String).flatMap(JSONDocument.object))
        let clients = try #require(settings["clients"] as? [[String: Any]])
        #expect(clients.map { $0["email"] as? String } == ["Laptop", "Phone"])
        // Fields the form does not own survive: sockopt, the TCP settings, the REALITY private key and fingerprint.
        let stream = try #require((body["streamSettings"] as? String).flatMap(JSONDocument.object))
        #expect((stream["sockopt"] as? [String: Any])?["tcpFastOpen"] as? Bool == true)
        #expect(stream["tcpSettings"] != nil)
        let reality = try #require(stream["realitySettings"] as? [String: Any])
        #expect(reality["privateKey"] as? String == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        #expect(reality["shortIds"] as? [String] == ["a1b2c3d4"])
        #expect((reality["settings"] as? [String: Any])?["fingerprint"] as? String == "firefox")
        let sniffing = try #require((body["sniffing"] as? String).flatMap(JSONDocument.object))
        #expect(sniffing["destOverride"] as? [String] == ["http", "tls"])
    }

    @Test func switchingOffVisionFlowSetsDisableFlow() throws {
        var draft = RealityInboundDraft.newDraft()
        draft.useVisionFlow = false
        let body = try JSONSerialization.jsonObject(with: draft.makeBody(existing: nil)) as? [String: Any]
        #expect(body?["disableFlow"] as? Bool == true)
    }

    @Test func aFailedAddIsReportedWithThePanelMessage() async {
        let transport = FakeTransport(.refused("Port 8444 is already in use"))
        var draft = RealityInboundDraft.newDraft()
        draft.privateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        draft.publicKey = "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A"
        do { try await client(transport).saveInbound(draft); Issue.record("expected an error") } catch {
            #expect(error as? PanelError == .api("Port 8444 is already in use"))
        }
    }

    @Test func anInvalidDraftNeverReachesTheNetwork() async {
        let transport = FakeTransport()
        var draft = RealityInboundDraft.newDraft()
        draft.port = 0
        draft.privateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        draft.publicKey = "Dm0Pu3bQ1xYb7mYk2eV9tCq4sHn8LrXa5oJfWzUiG6A"
        do { try await client(transport).saveInbound(draft); Issue.record("expected an error") } catch {
            #expect(error is PanelError)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func keyPairDecodes() async throws {
        let pair = try await client(FakeTransport(.ok(#"{"privateKey": "a", "publicKey": "b"}"#))).newRealityKeyPair()
        #expect(pair == RealityKeyPair(privateKey: "a", publicKey: "b"))
    }
}
