import CasaKit
import Foundation
import UIKit
import UserNotifications

// Everything the Inbounds, Clients and Status tabs do on the panel, plus sign-in, sign-out and the demo.
extension AppModel {
    // MARK: Inbounds

    func refreshInbounds() async {
        guard let client = panel else {
            inbounds = []; inboundsState = .notConfigured
            return
        }
        let gen = epoch
        guard inboundsFlight != gen else { return }
        inboundsFlight = gen
        let ticket = inboundTickets.begin()
        defer { if inboundsFlight == gen { inboundsFlight = nil } }
        if inboundsState != .loaded { inboundsState = .loading }
        do {
            let list = try await client.inbounds()
            guard gen == epoch, inboundTickets.accept(ticket) else { return }
            var fresh = list
            for index in fresh.indices where busyInbounds.contains(fresh[index].id) {
                if let local = inbounds.first(where: { $0.id == fresh[index].id }) { fresh[index].enable = local.enable }
            }
            inbounds = fresh
            inboundsState = .loaded
        } catch {
            guard gen == epoch, inboundTickets.accept(ticket) else { return }
            inbounds = []
            inboundsState = Self.loadState(for: error)
        }
    }

    func setInbound(_ inbound: Inbound, enabled: Bool) async {
        guard let panel, !busyInbounds.contains(inbound.id) else { return }
        let gen = epoch
        busyInbounds.insert(inbound.id)
        if let index = inbounds.firstIndex(where: { $0.id == inbound.id }) { inbounds[index].enable = enabled }
        defer { if gen == epoch { busyInbounds.remove(inbound.id) } }
        do {
            try await panel.setInboundEnabled(id: inbound.id, enabled: enabled)
            guard gen == epoch else { return }
            inboundsFlight = nil
            await refreshInbounds()
            await refreshStatus()
        } catch {
            guard gen == epoch else { return }
            if let index = inbounds.firstIndex(where: { $0.id == inbound.id }) { inbounds[index].enable = !enabled }
            actionError = "Could not \(enabled ? "turn on" : "turn off") \(inbound.remark). \(error.localizedDescription)"
        }
    }

    func resetTraffic(of inbound: Inbound) async {
        await perform("reset the traffic of \(inbound.remark)") { try await $0.resetInboundTraffic(id: inbound.id) }
        await reloadAfterInboundChange()
    }

    func delete(_ inbound: Inbound) async {
        await perform("delete \(inbound.remark)") { try await $0.deleteInbound(id: inbound.id) }
        await reloadAfterInboundChange()
    }

    /// Adds or updates an inbound. Throws so the editor can show the message and stay open.
    func save(_ draft: RealityInboundDraft) async throws {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        try await panel.saveInbound(draft)
        await reloadAfterInboundChange()
    }

    func inboundDetail(id: Int) async throws -> InboundDetail {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        return try await panel.inbound(id: id)
    }

    func newRealityKeyPair() async throws -> RealityKeyPair {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        return try await panel.newRealityKeyPair()
    }

    private func reloadAfterInboundChange() async {
        inboundsFlight = nil
        async let inbounds: Void = refreshInbounds()
        async let clients: Void = refreshClients(force: true)
        async let status: Void = refreshStatus()
        _ = await (inbounds, clients, status)
    }

    // MARK: Clients

    func clientDetail(email: String) async throws -> ClientDetail {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        return try await panel.client(email: email)
    }

    /// Adds or updates a client. Throws so the editor can show the message and stay open.
    func save(_ draft: ClientDraft) async throws {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        try await panel.saveClient(draft)
        await refreshClients(force: true)
        inboundsFlight = nil
        await refreshInbounds()
    }

    func resetTraffic(of client: VPNClient) async {
        await perform("reset the traffic of \(client.email)") { try await $0.resetClientTraffic(email: client.email) }
        await refreshClients(force: true)
    }

    func delete(_ client: VPNClient) async {
        await perform("delete \(client.email)") { try await $0.deleteClient(email: client.email) }
        await refreshClients(force: true)
        inboundsFlight = nil
        await refreshInbounds()
    }

    /// The share links of a client, one per inbound, and the subscription base for the link below them.
    func shareLinks(email: String) async throws -> [String] {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        if advertisedSubscriptionBase == nil {
            advertisedSubscriptionBase = (try? await panel.subscriptionBase()) ?? nil
        }
        return try await panel.clientLinks(email: email)
    }

    // MARK: Xray

    func restartXray() async {
        await perform("restart Xray") { try await $0.restartXray() }
        await refreshStatus()
    }

    func stopXray() async {
        await perform("stop Xray") { try await $0.stopXray() }
        await refreshStatus()
    }

    func xrayLog(count: Int, filter: String) async throws -> [XrayLogEntry] {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        return try await panel.xrayLog(count: count, filter: filter)
    }

    func panelLog(count: Int, level: String) async throws -> [String] {
        guard let panel else { throw PanelError.invalidRequest("Sign in first.") }
        return try await panel.panelLog(count: count, level: level)
    }

    /// Runs a change on the panel and reports a failure as an alert.
    private func perform(_ what: String, _ work: (any PanelAPI) async throws -> Void) async {
        guard let panel else { return }
        let gen = epoch
        do {
            try await work(panel)
        } catch {
            guard gen == epoch else { return }
            actionError = "Could not \(what). \(error.localizedDescription)"
        }
    }

    static func loadState(for error: Error) -> LoadState {
        if let error = error as? PanelError { return state(for: error.kind) }
        return .failed(error.localizedDescription)
    }

    // MARK: Sign-in and sign-out

    /// Signs in to the panel, makes the app's own API token and saves the connection (the password is dropped).
    /// The relay settings stay as they are. Order: the new settings are saved first; only then is the app's
    /// earlier token deleted. If the save fails the new token is deleted and the old settings stay. A sign-in
    /// that finishes after Sign out, Cancel or the demo is dropped and its token deleted.
    @discardableResult
    func signIn(address: String, username: String, password: String, twoFactor: String, headers: [CustomHeader]) async throws -> PanelSignIn.Result {
        try await signInCoordinator.signIn(
            address: address, username: username, password: password, twoFactorCode: twoFactor,
            headers: headers, deviceName: UIDevice.current.name
        ) { [unowned self] result in
            let old = settings
            var merged = old
            merged.panelURL = result.settings.panelURL
            merged.panelToken = result.settings.panelToken
            merged.panelUser = result.settings.panelUser
            merged.panelTokenID = result.settings.panelTokenID
            merged.panelTokenName = result.settings.panelTokenName
            merged.panelSession = result.settings.panelSession
            merged.panelCSRF = result.settings.panelCSRF
            merged.panelHeaders = result.settings.panelHeaders
            guard save(merged) else {
                throw PanelError.invalidRequest(
                    "The iPhone Keychain refused to save the sign-in\(saveError.map { ": \($0)" } ?? ".") You are not signed in; try again."
                )
            }
            signOutNote = nil
            showReauth = false
            return old
        }
    }

    /// Stops a sign-in that is still running (the Cancel button of the sign-in sheet).
    func cancelSignIn() {
        signInCoordinator.cancel()
    }

    /// Signs out. The app deletes its own panel token when the panel answers, tells the relay to
    /// forget this device, then deletes every Keychain item it keeps for the server: the panel
    /// address, token or session, extra headers, the relay address and token, and the subscription base.
    /// The person is signed out in memory in every case. If the Keychain refuses a delete, the sign-in
    /// screen says what is still stored and the next launch tries again.
    func signOut() async {
        if isDemo { exitDemo(); return }
        cancelSignIn()
        let old = settings
        var notes: [String] = []
        if old.ownsPanelToken, let client = PanelClient(settings: old, transport: transport) {
            do {
                try await client.deleteApiToken(id: old.panelTokenID)
            } catch {
                notes.append(
                    "The panel could not delete the token \"\(old.panelTokenName)\": \(error.localizedDescription) "
                        + "Delete it in the panel under Settings, API tokens."
                )
            }
        }
        cancelSignIn()
        // In memory first (this also unregisters the device from the relay, best effort), then the Keychain.
        apply(.empty)
        if store.deleteAllRetrying(attempts: 3) != nil {
            defaults.set(true, forKey: DefaultsKey.pendingWipe)
            notes.append(Self.wipeNote(left: store.storedItems()))
        } else {
            defaults.removeObject(forKey: DefaultsKey.pendingWipe)
        }
        signOutNote = notes.isEmpty ? nil : "Signed out on this iPhone. " + notes.joined(separator: " ")
        signInSkipped = false
        defaults.set(false, forKey: "signInSkipped")
        selectedTab = .status
    }

    /// Replaces the extra headers of the signed-in connection (Settings).
    func saveHeaders(_ headers: [CustomHeader]) {
        var copy = settings
        copy.panelHeaders = headers
        save(copy)
    }

    // MARK: Demo

    func startDemo() {
        cancelSignIn()
        resetDataForNewSource()
        isDemo = true
        demoPanel = DemoPanel()
        selectedTab = .status
        Task { await refreshAll() }
    }

    func exitDemo() {
        resetDataForNewSource()
        isDemo = false
        demoPanel = nil
        localAlerts = []
        selectedTab = .status
        Task { await refreshAll() }
    }

    private func resetDataForNewSource() {
        epoch += 1
        relayFlight = nil; statusFlight = nil; inboundsFlight = nil
        busyClients = []; busyInbounds = []
        clients = []; onlineEmails = []; inbounds = []; serverStatus = nil; alerts = []; monitor = nil
        advertisedSubscriptionBase = nil
        relayState = .idle; statusState = .idle; inboundsState = .idle; clientsState = .idle
    }

    /// "Send test alert" in the demo: a local notification and an entry in the Alerts tab. Nothing leaves the phone.
    func sendDemoTestAlert() async {
        isSendingTest = true
        defer { isSendingTest = false }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        let now = Date()
        localAlerts.insert(
            VPNAlert(
                id: "demo-test-\(Int(now.timeIntervalSince1970))", kind: "test", severity: .info,
                title: "Test alert", body: "This is a test notification from the demo. Real alerts come from your relay.",
                at: now, source: "demo"
            ),
            at: 0
        )
        await refreshRelay()
        guard granted else {
            testMessage = "Test alert added to the Alerts tab. Allow notifications in the iOS Settings app to also see a banner."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Test alert"
        content.body = "This is a test notification from the demo."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        testMessage = "Test alert sent to this iPhone."
    }
}
