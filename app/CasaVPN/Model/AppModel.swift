import CasaKit
import CryptoKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// How one part of a screen is doing. Each source (relay, panel status, panel clients) has its own.
enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case notConfigured
    case unreachable
    case unauthorized
    case forbidden
    case failed(String)

    var isFailure: Bool {
        switch self {
        case .unreachable, .unauthorized, .forbidden, .failed: true
        default: false
        }
    }
}

enum AppTab: Hashable {
    case status, clients, alerts, settings
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: State the views read

    var selectedTab: AppTab = .status
    /// Alert ids pushed on the Alerts tab's navigation stack.
    var alertPath: [String] = []
    var pendingPairing: ConnectionSettings?

    private(set) var settings: ConnectionSettings

    private(set) var monitor: Monitor?
    private(set) var alerts: [VPNAlert] = []
    private(set) var relayState: LoadState = .idle

    private(set) var serverStatus: ServerStatus?
    private(set) var statusState: LoadState = .idle

    private(set) var clients: [VPNClient] = []
    private(set) var onlineEmails: Set<String> = []
    private(set) var clientsState: LoadState = .idle
    private(set) var busyClients: Set<String> = []

    var clientError: String?

    private(set) var pushEnabled: Bool
    private(set) var pushAuthorization: UNAuthorizationStatus = .notDetermined
    private(set) var pushMessage: String?
    private(set) var testMessage: String?
    private(set) var isSendingTest = false
    private(set) var saveError: String?

    // MARK: Private

    private let store: SettingsStore
    private let defaults: UserDefaults
    private var deviceToken: String?
    /// Bumped whenever the connection details change. A result that started under an older
    /// epoch is dropped, so a slow answer from the old server never shows up under the new one.
    private var epoch = 0
    private var transport = URLSessionTransport()
    private var relayFlight: Int?
    private var statusFlight: Int?
    /// The refresh that is running, by epoch and ticket. Whoever set it clears it, and only if it is still theirs.
    private var clientsFlight: (epoch: Int, ticket: Int)?
    private var clientTickets = SnapshotSequencer()
    /// Push changes run one after another, in the order they were asked for.
    private var pushChain: Task<Void, Never>?
    private var pushApplied: Bool

    private enum DefaultsKey {
        static let pushEnabled = "pushEnabled"
        static let registrationFingerprint = "registrationFingerprint"
        static let registeredAt = "registeredAt"
        /// The device token the relay holds for this phone; removed only after the relay confirmed a delete.
        static let registeredToken = "registeredToken"
    }

    /// A registration is repeated after this long even when nothing changed, in case the relay dropped the device.
    private static let registrationMaxAge: TimeInterval = 7 * 24 * 3600

    init(store: SettingsStore = SettingsStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.settings = store.load()
        let push = defaults.bool(forKey: DefaultsKey.pushEnabled)
        self.pushEnabled = push
        self.pushApplied = push
    }

    // MARK: Clients of the two servers

    private var relayClient: RelayClient? {
        guard settings.hasRelay, let base = settings.relayBase else { return nil }
        return RelayClient(baseURL: base, token: settings.relayToken, transport: transport)
    }

    private var panelClient: PanelClient? {
        guard settings.hasPanel, let base = settings.panelBase else { return nil }
        return PanelClient(baseURL: base, token: settings.panelToken, transport: transport)
    }

    // MARK: Launch

    func start() async {
        await refreshPushAuthorization()
        if pushEnabled, pushAuthorization == .authorized || pushAuthorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await refreshAll()
    }

    func refreshAll() async {
        async let relay: Void = refreshRelay()
        async let status: Void = refreshStatus()
        async let clients: Void = refreshClients()
        _ = await (relay, status, clients)
    }

    // MARK: Relay

    func refreshRelay() async {
        guard let client = relayClient else {
            monitor = nil; alerts = []; relayState = .notConfigured
            return
        }
        let gen = epoch
        guard relayFlight != gen else { return }
        relayFlight = gen
        defer { if relayFlight == gen { relayFlight = nil } }
        if relayState != .loaded { relayState = .loading }
        do {
            let response = try await client.alerts(limit: 100)
            guard gen == epoch else { return }
            alerts = response.alerts
            monitor = response.monitor
            relayState = .loaded
        } catch {
            guard gen == epoch else { return }
            if let error = error as? RelayError {
                relayState = Self.state(for: error.kind)
            } else {
                relayState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Panel

    func refreshStatus() async {
        guard let client = panelClient else {
            serverStatus = nil; statusState = .notConfigured
            return
        }
        let gen = epoch
        guard statusFlight != gen else { return }
        statusFlight = gen
        defer { if statusFlight == gen { statusFlight = nil } }
        if statusState != .loaded { statusState = .loading }
        do {
            let status = try await client.serverStatus()
            guard gen == epoch else { return }
            serverStatus = status
            statusState = .loaded
        } catch {
            guard gen == epoch else { return }
            serverStatus = nil
            if let error = error as? PanelError {
                statusState = Self.state(for: error.kind)
            } else {
                statusState = .failed(error.localizedDescription)
            }
        }
    }

    /// `force` runs even when a refresh is already in flight (after a toggle: that refresh may
    /// have started before the change). Answers are applied in the order the requests started.
    func refreshClients(force: Bool = false) async {
        guard let client = panelClient else {
            clients = []; onlineEmails = []; clientsState = .notConfigured
            return
        }
        let gen = epoch
        if !force, clientsFlight?.epoch == gen { return }
        let ticket = clientTickets.begin()
        clientsFlight = (gen, ticket)
        defer { if clientsFlight?.ticket == ticket { clientsFlight = nil } }
        if clientsState != .loaded { clientsState = .loading }
        do {
            let snapshot = try await client.clients()
            guard gen == epoch, clientTickets.accept(ticket) else { return }
            var fresh = snapshot.clients
            // A switch that is being changed right now keeps what the user just chose.
            for index in fresh.indices where busyClients.contains(fresh[index].email) {
                if let local = clients.first(where: { $0.email == fresh[index].email }) { fresh[index].enable = local.enable }
            }
            clients = fresh
            onlineEmails = snapshot.online
            clientsState = .loaded
        } catch {
            guard gen == epoch, clientTickets.accept(ticket) else { return }
            clients = []; onlineEmails = []
            if let error = error as? PanelError {
                clientsState = Self.state(for: error.kind)
            } else {
                clientsState = .failed(error.localizedDescription)
            }
        }
    }

    func isOnline(_ client: VPNClient) -> Bool { onlineEmails.contains(client.email) }

    /// Turns a client on or off. The switch moves at once and moves back if the panel refuses.
    /// A change of connection details while it runs cancels it, and its result is dropped.
    func setClient(_ client: VPNClient, enabled: Bool) async {
        guard let panel = panelClient, !busyClients.contains(client.email) else { return }
        let gen = epoch
        busyClients.insert(client.email)
        replace(email: client.email) { $0.enable = enabled }
        defer { if gen == epoch { busyClients.remove(client.email) } }
        do {
            try await panel.setClientEnabled(email: client.email, enabled: enabled)
            guard gen == epoch else { return }
            // Always read the list again, even if a refresh is running: that one may predate the change.
            await refreshClients(force: true)
        } catch {
            guard gen == epoch else { return }
            replace(email: client.email) { $0.enable = !enabled }
            clientError = "Could not \(enabled ? "turn on" : "turn off") \(client.email). \(error.localizedDescription)"
        }
    }

    private func replace(email: String, _ change: (inout VPNClient) -> Void) {
        guard let index = clients.firstIndex(where: { $0.email == email }) else { return }
        change(&clients[index])
    }

    func subscriptionLink(for client: VPNClient) -> String? {
        settings.subscriptionLink(subId: client.subId)
    }

    // MARK: Alerts

    func alert(id: String) -> VPNAlert? { alerts.first { $0.id == id } }

    /// A tapped push. Shows the alert, loading the history first if it is not there yet.
    func openAlert(id: String?) {
        selectedTab = .alerts
        guard let id, !id.isEmpty else { return }
        alertPath = [id]
        Task { await refreshRelay() }
    }

    func pushArrivedInForeground() {
        Task { await refreshRelay() }
    }

    // MARK: Settings

    func save(_ new: ConnectionSettings) {
        let old = settings
        let normalized = new.normalized()
        do {
            try store.save(normalized)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            return
        }
        guard normalized != old else { return }
        settings = normalized

        // New epoch: cancel everything in flight and forget the old server's data.
        epoch += 1
        transport.cancelAll()
        transport = URLSessionTransport()
        relayFlight = nil; statusFlight = nil; clientsFlight = nil
        busyClients = []
        clients = []; onlineEmails = []; serverStatus = nil; alerts = []; monitor = nil
        relayState = .idle; statusState = .idle; clientsState = .idle

        let relayChanged = old.relayURL != normalized.relayURL || old.relayToken != normalized.relayToken
        if relayChanged {
            // Whatever the push switch says now: if the old relay ever got this device, remove it there.
            enqueuePush {
                if let token = self.registeredToken, old.hasRelay, let base = old.relayBase {
                    // Best effort: the old credentials are not kept after this, so there is no second try.
                    try? await RelayClient(baseURL: base, token: old.relayToken).deleteDevice(token: token)
                }
                self.clearRegistrationRecord()
            }
        }
        Task {
            await refreshAll()
            await syncRegistration()
        }
    }

    func proposePairing(from text: String) -> String? {
        do {
            pendingPairing = try PairLink.parse(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func handleIncoming(url: URL) {
        selectedTab = .settings
        do {
            pendingPairing = try PairLink.parse(url)
        } catch {
            saveError = error.localizedDescription
        }
    }

    func confirmPairing() {
        guard let pending = pendingPairing else { return }
        pendingPairing = nil
        save(pending)
    }

    func cancelPairing() { pendingPairing = nil }

    // MARK: Push

    func refreshPushAuthorization() async {
        pushAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The switch in Settings. The wish is recorded at once; the work runs in a queue, and the
    /// last wish wins (Off then On quickly cannot leave the old Off to unregister afterwards).
    func setPushEnabled(_ on: Bool) async {
        pushMessage = nil
        pushEnabled = on
        defaults.set(on, forKey: DefaultsKey.pushEnabled)
        await enqueuePush { await self.applyPush() }.value
    }

    @discardableResult
    private func enqueuePush(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = pushChain
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        pushChain = task
        return task
    }

    /// Brings the real push state in line with `pushEnabled`. Runs only inside the queue.
    private func applyPush() async {
        let wanted = pushEnabled
        guard wanted != pushApplied else { return }
        if wanted {
            // Time-sensitive delivery comes from the entitlement; the `.timeSensitive` option is deprecated.
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshPushAuthorization()
            guard granted else {
                pushEnabled = false
                defaults.set(false, forKey: DefaultsKey.pushEnabled)
                pushMessage = "Notifications are turned off for CasaVPN. Allow them in the iOS Settings app."
                return
            }
            pushApplied = true
            UIApplication.shared.registerForRemoteNotifications()
            await performRegistration()
        } else {
            pushApplied = false
            if let token = registeredToken ?? deviceToken, let client = relayClient {
                do {
                    try await client.deleteDevice(token: token)
                    clearRegistrationRecord()
                } catch {
                    // The record stays: a later relay change still removes the device from this relay.
                    pushMessage = "Push is off on this iPhone, but the relay could not be told: \(error.localizedDescription)"
                }
            } else {
                clearRegistrationRecord()
            }
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    func didRegisterForPush(token: Data) {
        deviceToken = DeviceToken.hex(token)
        Task { await syncRegistration() }
    }

    func didFailToRegisterForPush(_ error: Error) {
        pushMessage = "This iPhone could not register for push: \(error.localizedDescription)"
    }

    func syncRegistration() async {
        await enqueuePush { await self.performRegistration() }.value
    }

    /// Tells the relay about this device. Repeats only when the token, the relay or the name changed,
    /// or after a week. Runs only inside the queue.
    private func performRegistration() async {
        guard pushEnabled, pushApplied, let token = deviceToken, let client = relayClient else { return }
        let registration = DeviceRegistration(token: token, environment: .current, name: UIDevice.current.name)
        let fingerprint = Self.fingerprint(registration: registration, settings: settings)
        let age = defaults.object(forKey: DefaultsKey.registeredAt) as? Date
        if defaults.string(forKey: DefaultsKey.registrationFingerprint) == fingerprint,
           let age, Date().timeIntervalSince(age) < Self.registrationMaxAge {
            return
        }
        let gen = epoch
        do {
            try await client.registerDevice(registration)
            guard gen == epoch else { return }
            defaults.set(fingerprint, forKey: DefaultsKey.registrationFingerprint)
            defaults.set(Date(), forKey: DefaultsKey.registeredAt)
            defaults.set(token, forKey: DefaultsKey.registeredToken)
            pushMessage = nil
        } catch {
            guard gen == epoch else { return }
            pushMessage = "This iPhone could not be registered with the relay: \(error.localizedDescription)"
        }
    }

    func sendTestAlert() async {
        guard let client = relayClient else {
            testMessage = "Set the relay URL and token first."
            return
        }
        isSendingTest = true
        defer { isSendingTest = false }
        do {
            let result = try await client.sendTest()
            let count = result.pushed ?? 0
            testMessage = count > 0
                ? "Test alert sent to \(count) \(count == 1 ? "device" : "devices")."
                : "Test alert stored. No device is registered for push yet."
            await refreshRelay()
        } catch {
            testMessage = error.localizedDescription
        }
    }

    // MARK: Helpers

    private var registeredToken: String? { defaults.string(forKey: DefaultsKey.registeredToken) }

    private func clearRegistrationRecord() {
        defaults.removeObject(forKey: DefaultsKey.registrationFingerprint)
        defaults.removeObject(forKey: DefaultsKey.registeredAt)
        defaults.removeObject(forKey: DefaultsKey.registeredToken)
    }

    private static func fingerprint(registration: DeviceRegistration, settings: ConnectionSettings) -> String {
        let text = [registration.token, registration.environment.rawValue, registration.name, settings.relayURL, settings.relayToken]
            .joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func state(for kind: FailureKind) -> LoadState {
        switch kind {
        case .unreachable: .unreachable
        case .unauthorized: .unauthorized
        case .forbidden: .forbidden
        case .other(let message): .failed(message)
        }
    }
}
