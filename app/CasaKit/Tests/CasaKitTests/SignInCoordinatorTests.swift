import Foundation
import Testing
@testable import CasaKit

/// Calls `hook` with the request number (1-based) before the wrapped transport answers it.
final class HookTransport: HTTPTransport, @unchecked Sendable {
    let inner: FakeTransport
    let hook: @Sendable (Int, URLRequest) -> Void
    private let lock = NSLock()
    private var count = 0

    init(_ inner: FakeTransport, hook: @escaping @Sendable (Int, URLRequest) -> Void) {
        self.inner = inner
        self.hook = hook
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let number: Int = { lock.lock(); defer { lock.unlock() }; count += 1; return count }()
        hook(number, request)
        return try await inner.send(request)
    }
}

/// Where `commit` leaves what it saw.
final class Saved: @unchecked Sendable {
    var results: [PanelSignIn.Result] = []
    var requestsAtCommit = 0
}

@Suite("SignInCoordinator")
struct SignInCoordinatorTests {
    static let cookie = ["Set-Cookie": "3x-ui=cookie-one; Path=/secret-path/; HttpOnly"]

    func replies() -> [FakeTransport.Reply] {
        [
            .full(status: 200, body: #"{"success": true, "obj": "csrf-one"}"#, headers: Self.cookie),
            .full(status: 200, body: #"{"success": true, "msg": "ok"}"#, headers: ["Set-Cookie": "3x-ui=cookie-two; Path=/secret-path/; HttpOnly"]),
            .full(status: 200, body: #"{"success": true, "obj": "csrf-two"}"#, headers: [:]),
            .ok(#"{"id": 9, "name": "CasaVPN Test Phone", "token": "fresh-admin-token", "enabled": true, "createdAt": 1, "scope": "admin", "expiresAt": 0}"#),
            .ok(), .ok(),
        ]
    }

    func old() -> ConnectionSettings {
        var old = ConnectionSettings(panelURL: "https://vpn.example.com:8443/secret-path", panelToken: "old-token")
        old.panelTokenID = 5
        old.panelTokenName = "CasaVPN Test Phone"
        return old
    }

    func run(_ coordinator: SignInCoordinator, commit: @escaping @MainActor @Sendable (PanelSignIn.Result) throws -> ConnectionSettings) async throws -> PanelSignIn.Result {
        try await coordinator.signIn(
            address: "https://vpn.example.com:8443/secret-path", username: "admin", password: "correct horse",
            deviceName: "Test Phone", commit: commit
        )
    }

    @Test func deletesTheOldTokenOnlyAfterTheNewSettingsAreSaved() async throws {
        let fake = FakeTransport(replies())
        let saved = Saved()
        let previous = old()
        let result = try await run(SignInCoordinator(transport: fake)) { result in
            saved.results.append(result)
            saved.requestsAtCommit = fake.requests.count
            return previous
        }
        #expect(result.settings.panelTokenID == 9)
        #expect(saved.results.count == 1)
        // Four requests made the token; the old one was deleted after the commit, not before.
        #expect(saved.requestsAtCommit == 4)
        #expect(fake.requests.count == 5)
        #expect(fake.requests[4].path == "/secret-path/panel/api/setting/apiTokens/delete/5")
    }

    @Test func aFailedSaveDeletesTheNewTokenAndKeepsTheOldOne() async {
        struct KeychainRefused: Error {}
        let fake = FakeTransport(replies())
        do {
            _ = try await run(SignInCoordinator(transport: fake)) { _ in throw KeychainRefused() }
            Issue.record("expected the commit error")
        } catch {
            #expect(error is KeychainRefused)
        }
        let deletes = fake.requests.map(\.path).filter { $0.contains("apiTokens/delete") }
        #expect(deletes == ["/secret-path/panel/api/setting/apiTokens/delete/9"])
    }

    @Test func aSignInThatFinishesAfterCancelSavesNothingAndDeletesItsToken() async {
        let fake = FakeTransport(replies())
        do {
            // Sign out arrives while the token request is in flight (request 4).
            let result = try await runHooked(fake: fake)
            Issue.record("expected cancellation, got \(result.settings.panelTokenID)")
        } catch {
            #expect(error as? PanelError == .cancelled)
        }
        let deletes = fake.requests.map(\.path).filter { $0.contains("apiTokens/delete") }
        #expect(deletes == ["/secret-path/panel/api/setting/apiTokens/delete/9"])
    }

    /// One coordinator whose transport cancels that coordinator on the fourth request.
    func runHooked(fake: FakeTransport) async throws -> PanelSignIn.Result {
        final class Box: @unchecked Sendable { var coordinator: SignInCoordinator? }
        let box = Box()
        let coordinator = SignInCoordinator(transport: HookTransport(fake) { number, _ in
            if number == 4 { box.coordinator?.cancel() }
        })
        box.coordinator = coordinator
        return try await run(coordinator) { _ in
            Issue.record("a cancelled sign-in must not be saved")
            return ConnectionSettings.empty
        }
    }

    @Test func aSessionFallbackIsNotRevoked() async throws {
        // No token was made (the panel refused), so there is nothing to delete after a failed save.
        var replies = replies()
        replies[3] = .refused("not allowed")
        let fake = FakeTransport(replies)
        struct Refused: Error {}
        do {
            _ = try await run(SignInCoordinator(transport: fake)) { _ in throw Refused() }
        } catch {}
        #expect(fake.requests.map(\.path).filter { $0.contains("apiTokens/delete") }.isEmpty)
    }
}
