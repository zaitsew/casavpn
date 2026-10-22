import Foundation
import Testing
@testable import CasaKit

@Suite("PanelSignIn")
struct PanelSignInTests {
    static let cookieHeader = ["Set-Cookie": "3x-ui=cookie-one; Path=/secret-path/; HttpOnly"]
    static let cookieTwo = ["Set-Cookie": "3x-ui=cookie-two; Path=/secret-path/; HttpOnly"]
    static let cookieThree = ["Set-Cookie": "3x-ui=cookie-three; Path=/secret-path/; HttpOnly"]

    func csrf(_ token: String, headers: [String: String]) -> FakeTransport.Reply {
        .full(status: 200, body: #"{"success": true, "obj": "\#(token)"}"#, headers: headers)
    }

    let loginOK = FakeTransport.Reply.full(status: 200, body: #"{"success": true, "msg": "Logged in"}"#, headers: PanelSignInTests.cookieTwo)
    let tokenOK = FakeTransport.Reply.ok(#"{"id": 9, "name": "CasaVPN Test Phone", "token": "fresh-admin-token", "enabled": true, "createdAt": 1, "scope": "admin", "expiresAt": 0}"#)

    func signIn(
        _ transport: FakeTransport, address: String = "https://vpn.example.com:8443/secret-path/panel/",
        twoFactor: String = "", headers: [CustomHeader] = []
    ) async throws -> PanelSignIn.Result {
        try await PanelSignIn(transport: transport, deviceName: "Test Phone")
            .signIn(address: address, username: "admin", password: "correct horse", twoFactorCode: twoFactor, headers: headers)
    }

    @Test func signsInThenMakesAnAdminTokenAndKeepsOnlyTheToken() async throws {
        let transport = FakeTransport(csrf("csrf-one", headers: Self.cookieHeader), loginOK, csrf("csrf-two", headers: [:]), tokenOK)
        let result = try await signIn(transport)

        #expect(result.madeToken)
        #expect(result.tokenProblem == nil)
        #expect(result.settings.panelURL == "https://vpn.example.com:8443/secret-path")
        #expect(result.settings.panelToken == "fresh-admin-token")
        #expect(result.settings.panelTokenID == 9)
        #expect(result.settings.panelTokenName == "CasaVPN Test Phone")
        #expect(result.settings.panelUser == "admin")
        #expect(result.settings.panelSession.isEmpty)
        #expect(result.settings.ownsPanelToken)
        // The password is gone: it is not in the saved settings.
        let saved = String(decoding: try JSONEncoder().encode(result.settings), as: UTF8.self)
        #expect(!saved.contains("correct horse"))

        let sent = transport.requests
        #expect(sent.map(\.path) == [
            "/secret-path/csrf-token", "/secret-path/login", "/secret-path/csrf-token",
            "/secret-path/panel/api/setting/apiTokens/create",
        ])
        #expect(sent[0].httpMethod == "GET")
        // The login is a form with the CSRF token and the cookie from the first answer.
        #expect(sent[1].httpMethod == "POST")
        #expect(sent[1].value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-one")
        #expect(sent[1].value(forHTTPHeaderField: "Cookie") == "3x-ui=cookie-one")
        #expect(sent[1].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(sent[1].bodyText == "username=admin&password=correct%20horse")
        // The token is made with the signed-in session (the cookie the login renewed).
        #expect(sent[3].value(forHTTPHeaderField: "Cookie") == "3x-ui=cookie-two")
        #expect(sent[3].value(forHTTPHeaderField: "X-CSRF-Token") == "csrf-two")
        #expect(sent[3].value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(sent[3].jsonBody["name"] as? String == "CasaVPN Test Phone")
        #expect(sent[3].jsonBody["scope"] as? String == "admin")
        // No request except the login carries the password.
        #expect(sent.filter { $0.bodyText.contains("correct") }.count == 1)
    }

    @Test func sendsTheTwoFactorCodeWhenGiven() async throws {
        let transport = FakeTransport(csrf("c", headers: Self.cookieHeader), loginOK, csrf("c2", headers: [:]), tokenOK)
        _ = try await signIn(transport, twoFactor: " 123456 ")
        #expect(transport.requests[1].bodyText == "username=admin&password=correct%20horse&twoFactorCode=123456")
    }

    @Test func customHeadersGoOnEveryRequest() async throws {
        let transport = FakeTransport(csrf("c", headers: Self.cookieHeader), loginOK, csrf("c2", headers: [:]), tokenOK)
        let headers = [CustomHeader(name: "CF-Access-Client-Id", value: "id.access"), CustomHeader(name: "CF-Access-Client-Secret", value: "s3cret")]
        let result = try await signIn(transport, headers: headers)
        for request in transport.requests {
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
            #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "s3cret")
        }
        #expect(result.settings.panelHeaders == headers)
    }

    @Test func aWrongPasswordIsASignInFailureWithThePanelMessage() async {
        let transport = FakeTransport(
            csrf("c", headers: Self.cookieHeader),
            .response(status: 200, body: #"{"success": false, "msg": "The username or password is incorrect."}"#)
        )
        do {
            _ = try await signIn(transport)
            Issue.record("expected an error")
        } catch {
            guard case .signInFailed(let message)? = error as? PanelError else { Issue.record("wrong error \(error)"); return }
            #expect(message.contains("The username or password is incorrect."))
            #expect(message.contains("two-factor"))
        }
        #expect(transport.requests.count == 2)
    }

    @Test func aMissingBasePathIsReportedBeforeAnyPasswordIsSent() async {
        let transport = FakeTransport(.response(status: 404, body: ""))
        do {
            _ = try await signIn(transport)
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .notFound)
        }
        #expect(transport.requests.count == 1)
    }

    @Test func aRefusedNetworkIsNamedAsSuch() async {
        let transport = FakeTransport(.response(status: 403, body: "<html>403 Forbidden</html>"))
        do {
            _ = try await signIn(transport)
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .refusedByProxy(403))
        }
    }

    @Test func aTakenTokenNameGetsANumberedSuffix() async throws {
        let transport = FakeTransport(
            csrf("c", headers: Self.cookieHeader), loginOK, csrf("c2", headers: [:]),
            .refused("a token with that name already exists"), tokenOK
        )
        let result = try await signIn(transport)
        #expect(result.madeToken)
        let creates = transport.requests.filter { $0.path.hasSuffix("/apiTokens/create") }
        #expect(creates.map { $0.jsonBody["name"] as? String } == ["CasaVPN Test Phone", "CasaVPN Test Phone 2"])
    }

    @Test func whenNoTokenCanBeMadeTheSessionIsKept() async throws {
        let transport = FakeTransport(csrf("c", headers: Self.cookieHeader), loginOK, csrf("c2", headers: Self.cookieThree), .response(status: 404, body: ""))
        let result = try await signIn(transport)
        #expect(!result.madeToken)
        #expect(result.tokenProblem != nil)
        #expect(result.settings.panelToken.isEmpty)
        #expect(result.settings.panelSession == "cookie-three")
        #expect(result.settings.panelCSRF == "c2")
        #expect(result.settings.hasPanel)
        #expect(result.settings.panelCredential == .session(cookie: "cookie-three", csrf: "c2"))
    }

    @Test func aNetworkFailureWhileMakingTheTokenIsNotHiddenBehindASession() async {
        let transport = FakeTransport(csrf("c", headers: Self.cookieHeader), loginOK, csrf("c2", headers: [:]), .failure(.timedOut))
        do {
            _ = try await signIn(transport)
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError == .unreachable)
        }
    }

    @Test func emptyFieldsAreRefusedWithoutAnyRequest() async {
        let transport = FakeTransport()
        let signer = PanelSignIn(transport: transport, deviceName: "Phone")
        await #expect(throws: PanelError.invalidRequest("Enter the panel user name.")) {
            _ = try await signer.signIn(address: "vpn.example.com", username: " ", password: "x")
        }
        await #expect(throws: PanelError.invalidRequest("Enter the panel password.")) {
            _ = try await signer.signIn(address: "vpn.example.com", username: "admin", password: "")
        }
        await #expect(throws: PanelError.self) {
            _ = try await signer.signIn(address: "http://vpn.example.com", username: "admin", password: "x")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func aHeaderThatWouldReplaceTheAuthorizationIsRefused() async {
        let signer = PanelSignIn(transport: FakeTransport(), deviceName: "Phone")
        do {
            _ = try await signer.signIn(
                address: "vpn.example.com", username: "admin", password: "x",
                headers: [CustomHeader(name: "Authorization", value: "Bearer other")]
            )
            Issue.record("expected an error")
        } catch {
            #expect(error as? PanelError != nil)
        }
    }

    @Test func tokenNamesFitThePanelLimit() {
        #expect(PanelSignIn.tokenName(device: "Sam's iPhone") == "CasaVPN Sam's iPhone")
        #expect(PanelSignIn.tokenName(device: "") == "CasaVPN iPhone")
        let long = String(repeating: "x", count: 100)
        #expect(PanelSignIn.tokenName(device: long).count == 64)
        #expect(PanelSignIn.tokenName(device: long, attempt: 3).count == 64)
        #expect(PanelSignIn.tokenName(device: long, attempt: 3).hasSuffix(" 3"))
    }

    @Test func signingOutDeletesTheAppsOwnToken() async throws {
        let transport = FakeTransport(.ok())
        let client = PanelClient(baseURL: panelURL, token: "fresh-admin-token", transport: transport)
        try await client.deleteApiToken(id: 9)
        let request = transport.requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.path == "/secret-path/panel/api/setting/apiTokens/delete/9")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-admin-token")
        #expect(request.jsonBody["expectedScope"] as? String == "admin")
    }

    @Test func listsTheTokensWithoutTheirSecrets() async throws {
        let body = #"[{"id": 1, "name": "CasaVPN Test Phone", "enabled": true, "createdAt": 1736000000, "scope": "admin", "expiresAt": 0}]"#
        let tokens = try await PanelClient(baseURL: panelURL, token: "t", transport: FakeTransport(.ok(body))).apiTokens()
        #expect(tokens.map(\.name) == ["CasaVPN Test Phone"])
        #expect(tokens[0].token.isEmpty)
    }
}
