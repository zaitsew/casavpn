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
    private var relayFlight = false
    private var statusFlight = false
    private var clientsFlight = false

    private enum DefaultsKey {
        static let pushEnabled = "pushEnabled"
        static let registrationFingerprint = "registrationFingerprint"
        static let registeredAt = "registeredAt"
    }

    /// A registration is repeated after this long even when nothing changed, in case the relay dropped the device.
    private static let registrationMaxAge: TimeInterval = 7 * 24 * 3600

    init(store: SettingsStore = SettingsStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.settings = store.load()
        self.pushEnabled = defaults.bool(forKey: DefaultsKey.pushEnabled)
    }

    // MARK: Clients of the two servers

    private var relayClient: RelayClient? {
        guard settings.hasRelay, let base = settings.relayBase else { return nil }
        return RelayClient(baseURL: base, token: settings.relayToken)
    }

    private var panelClient: PanelClient? {
        guard settings.hasPanel, let base = settings.panelBase else { return nil }
        return PanelClient(baseURL: base, token: settings.panelToken)
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
        guard !relayFlight else { return }
        relayFlight = true
        defer { relayFlight = false }
        if relayState != .loaded { relayState = .loading }
        do {
            let response = try await client.alerts(limit: 100)
            alerts = response.alerts
            monitor = response.monitor
            relayState = .loaded
        } catch let error as RelayError {
            relayState = Self.state(for: error.kind)
        } catch {
            relayState = .failed(error.localizedDescription)
        }
    }

    // MARK: Panel

    func refreshStatus() async {
        guard let client = panelClient else {
            serverStatus = nil; statusState = .notConfigured
            return
        }
        guard !statusFlight else { return }
        statusFlight = true
        defer { statusFlight = false }
        if statusState != .loaded { statusState = .loading }
        do {
            serverStatus = try await client.serverStatus()
            statusState = .loaded
        } catch let error as PanelError {
            serverStatus = nil
            statusState = Self.state(for: error.kind)
        } catch {
            serverStatus = nil
            statusState = .failed(error.localizedDescription)
        }
    }

    func refreshClients() async {
        guard let client = panelClient else {
            clients = []; onlineEmails = []; clientsState = .notConfigured
            return
        }
        guard !clientsFlight else { return }
        clientsFlight = true
        defer { clientsFlight = false }
        if clientsState != .loaded { clientsState = .loading }
        do {
            let snapshot = try await client.clients()
            clients = snapshot.clients
            onlineEmails = snapshot.online
            clientsState = .loaded
        } catch let error as PanelError {
            clients = []; onlineEmails = []
            clientsState = Self.state(for: error.kind)
        } catch {
            clients = []; onlineEmails = []
            clientsState = .failed(error.localizedDescription)
        }
    }

    func isOnline(_ client: VPNClient) -> Bool { onlineEmails.contains(client.email) }

    /// Turns a client on or off. The switch moves at once and moves back if the panel refuses.
    func setClient(_ client: VPNClient, enabled: Bool) async {
        guard let panel = panelClient, !busyClients.contains(client.email) else { return }
        busyClients.insert(client.email)
        replace(email: client.email) { $0.enable = enabled }
        defer { busyClients.remove(client.email) }
        do {
            try await panel.setClientEnabled(email: client.email, enabled: enabled)
            await refreshClients()
        } catch {
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
        settings = normalized
        Task {
            let relayChanged = old.relayURL != normalized.relayURL || old.relayToken != normalized.relayToken
            if relayChanged, pushEnabled, let token = deviceToken, old.hasRelay, let base = old.relayBase {
                // Best effort: the old relay should stop pushing to this phone.
                try? await RelayClient(baseURL: base, token: old.relayToken).deleteDevice(token: token)
            }
            if relayChanged { clearRegistrationRecord() }
            await refreshAll()
            if pushEnabled { await syncRegistration() }
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

    func setPushEnabled(_ on: Bool) async {
        pushMessage = nil
        if on {
            // Time-sensitive delivery comes from the entitlement; the `.timeSensitive` option is deprecated.
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await refreshPushAuthorization()
            guard granted else {
                setPushFlag(false)
                pushMessage = "Notifications are turned off for CasaVPN. Allow them in the iOS Settings app."
                return
            }
            setPushFlag(true)
            UIApplication.shared.registerForRemoteNotifications()
            await syncRegistration()
        } else {
            setPushFlag(false)
            if let token = deviceToken, let client = relayClient {
                do { try await client.deleteDevice(token: token) } catch {
                    pushMessage = "Push is off on this iPhone, but the relay could not be told: \(error.localizedDescription)"
                }
            }
            clearRegistrationRecord()
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

    /// Tells the relay about this device. Repeats only when the token, the relay or the name changed,
    /// or after a week.
    func syncRegistration() async {
        guard pushEnabled, let token = deviceToken, let client = relayClient else { return }
        let registration = DeviceRegistration(token: token, environment: .current, name: UIDevice.current.name)
        let fingerprint = Self.fingerprint(registration: registration, settings: settings)
        let age = defaults.object(forKey: DefaultsKey.registeredAt) as? Date
        if defaults.string(forKey: DefaultsKey.registrationFingerprint) == fingerprint,
           let age, Date().timeIntervalSince(age) < Self.registrationMaxAge {
            return
        }
        do {
            try await client.registerDevice(registration)
            defaults.set(fingerprint, forKey: DefaultsKey.registrationFingerprint)
            defaults.set(Date(), forKey: DefaultsKey.registeredAt)
            pushMessage = nil
        } catch {
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

    private func setPushFlag(_ on: Bool) {
        pushEnabled = on
        defaults.set(on, forKey: DefaultsKey.pushEnabled)
    }

    private func clearRegistrationRecord() {
        defaults.removeObject(forKey: DefaultsKey.registrationFingerprint)
        defaults.removeObject(forKey: DefaultsKey.registeredAt)
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
