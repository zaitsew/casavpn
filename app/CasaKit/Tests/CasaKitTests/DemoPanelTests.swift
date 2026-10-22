import Foundation
import Testing
@testable import CasaKit

@Suite("DemoPanel")
struct DemoPanelTests {
    let fixedNow = Date(timeIntervalSince1970: 1_792_000_000)

    func demo() -> DemoPanel { DemoPanel(now: { Date(timeIntervalSince1970: 1_792_000_000) }) }

    @Test func hasAFictionalServerTwoInboundsAndSixGenericClients() async throws {
        let panel = demo()
        let status = try await panel.serverStatus()
        #expect(status.xray.state == .running)
        #expect(status.panelVersion == "3.10.2")
        #expect(status.publicIPv4?.hasPrefix("203.0.113.") == true)
        #expect(status.mem.total > 0 && status.disk.total > 0 && status.swap.total > 0)
        let inbounds = try await panel.inbounds()
        #expect(inbounds.count == 2)
        #expect(inbounds.map(\.protocolName) == ["vless", "shadowsocks"])
        #expect(inbounds[0].isEditableReality && !inbounds[1].isEditableReality)
        let snapshot = try await panel.clients()
        #expect(snapshot.clients.map(\.email).sorted() == ["Guest", "Laptop", "Phone", "TV", "Tablet", "Work-Laptop"])
        #expect(snapshot.online == ["Laptop", "Phone"])
        #expect(inbounds[0].clientCount == 5)
        #expect(inbounds[1].clientCount == 2)
    }

    @Test func containsNothingButDocumentationHostsAndAddresses() async throws {
        let panel = demo()
        var text = DemoPanel.host + " " + DemoPanel.subscriptionBaseURL + " "
        for client in try await panel.clients().clients {
            for link in try await panel.clientLinks(email: client.email) { text += link + " " }
        }
        for entry in try await panel.xrayLog(count: 100, filter: "") { text += entry.line + " " }
        text += " " + (try await panel.panelLog(count: 100, level: "info")).joined(separator: "\n") + " "
        text += (try await panel.serverStatus()).publicIPv4 ?? ""
        // Every dotted name with a letter in it is an example.com/.org/.net host.
        let names = text.matches(of: /[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/).map { String($0.0) }
        for name in names where name.contains(where: \.isLetter) {
            let documentation = ["example.com", "example.org", "example.net"].contains { name == $0 || name.hasSuffix("." + $0) }
            #expect(documentation, "\(name) is not a documentation host")
        }
        // Every four-part number is in 203.0.113.0/24.
        for match in text.matches(of: /\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/) {
            #expect(String(match.0).hasPrefix("203.0.113."), "\(match.0) is not a documentation address")
        }
    }

    @Test func togglingAClientChangesTheNextRead() async throws {
        let panel = demo()
        try await panel.setClientEnabled(email: "Phone", enabled: false)
        let snapshot = try await panel.clients()
        #expect(snapshot.clients.first { $0.email == "Phone" }?.enable == false)
        #expect(!snapshot.online.contains("Phone"))
    }

    @Test func resetTrafficZeroesTheClient() async throws {
        let panel = demo()
        try await panel.resetClientTraffic(email: "Phone")
        let phone = try #require(try await panel.clients().clients.first { $0.email == "Phone" })
        #expect(phone.usedBytes == 0)
    }

    @Test func addEditAndDeleteAClient() async throws {
        let panel = demo()
        try await panel.saveClient(ClientDraft(email: "Visitor", totalGB: 5, expiry: .afterFirstUse(days: 7), inboundIds: [1], flow: "xtls-rprx-vision"))
        var detail = try await panel.client(email: "Visitor")
        #expect(detail.totalBytes == 5 * 1_073_741_824)
        #expect(detail.expiryTime == -7 * 86_400_000)
        #expect(detail.subId.count == 16)
        var draft = ClientDraft(editing: detail)
        draft.totalGB = 20
        draft.comment = "Edited"
        try await panel.saveClient(draft)
        detail = try await panel.client(email: "Visitor")
        #expect(detail.totalBytes == 20 * 1_073_741_824)
        #expect(detail.comment == "Edited")
        try await panel.deleteClient(email: "Visitor")
        #expect(try await panel.clients().clients.count == 6)
        await #expect(throws: PanelError.self) { _ = try await panel.client(email: "Visitor") }
    }

    @Test func aDuplicateNameIsRefused() async throws {
        let panel = demo()
        await #expect(throws: PanelError.api("A client with this name already exists.")) {
            try await panel.saveClient(ClientDraft(email: "laptop", inboundIds: [1]))
        }
    }

    @Test func linksAndSubscriptionWork() async throws {
        let panel = demo()
        let links = try await panel.clientLinks(email: "Guest")
        #expect(links.count == 2)
        #expect(links[0].hasPrefix("vless://") && links[0].contains("security=reality") && links[0].contains("flow=xtls-rprx-vision"))
        #expect(links[1].hasPrefix("ss://"))
        let base = try #require(try await panel.subscriptionBase())
        let phone = try await panel.client(email: "Phone")
        let settings = ConnectionSettings(subURL: base)
        #expect(settings.subscriptionLink(subId: phone.subId) == "https://demo.example.com:2096/sub/\(phone.subId)")
    }

    @Test func inboundsToggleResetAddEditAndDelete() async throws {
        let panel = demo()
        try await panel.setInboundEnabled(id: 1, enabled: false)
        #expect(try await panel.inbounds().first { $0.id == 1 }?.enable == false)

        try await panel.resetInboundTraffic(id: 1)
        #expect(try await panel.inbounds().first { $0.id == 1 }?.usedBytes == 0)

        var draft = RealityInboundDraft.newDraft()
        draft.remark = "Travel"; draft.port = 8444
        try await panel.saveInbound(draft)
        let added = try #require(try await panel.inbounds().first { $0.remark == "Travel" })
        #expect(added.id == 3 && added.port == 8444 && added.isEditableReality)
        #expect(added.reality?.privateKey.count == 43)

        var edit = RealityInboundDraft(editing: added)
        edit.port = 8445
        try await panel.saveInbound(edit)
        #expect(try await panel.inbound(id: 3).inbound.port == 8445)

        await #expect(throws: PanelError.self) {
            var clash = RealityInboundDraft.newDraft()
            clash.port = 443
            try await panel.saveInbound(clash)
        }

        try await panel.deleteInbound(id: 3)
        #expect(try await panel.inbounds().count == 2)
    }

    @Test func deletingAnInboundRemovesClientsThatOnlyLivedThere() async throws {
        let panel = demo()
        try await panel.deleteInbound(id: 2)
        let names = try await panel.clients().clients.map(\.email)
        #expect(!names.contains("TV"))
        #expect(names.contains("Guest"))
    }

    @Test func xrayStopsAndStartsAndLogsFilter() async throws {
        let panel = demo()
        try await panel.stopXray()
        #expect(try await panel.serverStatus().xray.state == .stop)
        try await panel.restartXray()
        #expect(try await panel.serverStatus().xray.state == .running)
        let all = try await panel.xrayLog(count: 200, filter: "")
        let phone = try await panel.xrayLog(count: 200, filter: "Phone")
        #expect(all.count == 60)
        #expect(!phone.isEmpty && phone.count < all.count)
        #expect(phone.allSatisfy { $0.line.lowercased().contains("phone") })
        #expect(try await panel.xrayLog(count: 5, filter: "").count == 5)
        #expect(!(try await panel.panelLog(count: 100, level: "info")).isEmpty)
    }

    @Test func newKeyPairsAre43Characters() async throws {
        let pair = try await demo().newRealityKeyPair()
        #expect(pair.privateKey.count == 43 && pair.publicKey.count == 43)
    }
}
