import Foundation

/// Runs a panel sign-in so that its result is used only if it is still wanted, and so that a token the
/// app made but did not keep is deleted again on the panel.
///
/// - `cancel()` (sign-out, cancel, the demo) makes every sign-in that is still running stale: when it
///   finishes, its token is deleted and nothing is saved.
/// - The result is handed to `commit` on the main actor, where sign-out also runs, so a sign-out cannot
///   slip in between the check and the save.
/// - If `commit` throws (the Keychain refused the save), the new token is deleted and the old settings stay.
/// - Only after `commit` succeeded is the token of an earlier sign-in on the same panel deleted.
public final class SignInCoordinator: @unchecked Sendable {
    private let transport: any HTTPTransport
    private let lock = NSLock()
    private var generation = 0

    public init(transport: any HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Makes every sign-in that is running now stale.
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        generation += 1
    }

    private var current: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    /// `commit` saves the result and returns the settings it replaced.
    public func signIn(
        address: String, username: String, password: String, twoFactorCode: String = "",
        headers: [CustomHeader] = [], deviceName: String,
        commit: @escaping @MainActor @Sendable (PanelSignIn.Result) throws -> ConnectionSettings
    ) async throws -> PanelSignIn.Result {
        let ticket = current
        let result = try await PanelSignIn(transport: transport, deviceName: deviceName).signIn(
            address: address, username: username, password: password, twoFactorCode: twoFactorCode, headers: headers
        )
        let previous: ConnectionSettings
        do {
            previous = try await MainActor.run {
                guard self.current == ticket else { throw PanelError.cancelled }
                return try commit(result)
            }
        } catch {
            await revoke(result.settings, whenMade: result.madeToken)
            throw error
        }
        // The new settings are saved: the app's earlier token on the same panel is not needed any more.
        if result.madeToken, previous.ownsPanelToken, previous.panelURL == result.settings.panelURL,
           previous.panelTokenID != result.settings.panelTokenID, let client = PanelClient(settings: result.settings, transport: transport) {
            try? await client.deleteApiToken(id: previous.panelTokenID)
        }
        return result
    }

    private func revoke(_ settings: ConnectionSettings, whenMade made: Bool) async {
        guard made, settings.ownsPanelToken, let client = PanelClient(settings: settings, transport: transport) else { return }
        try? await client.deleteApiToken(id: settings.panelTokenID)
    }
}
