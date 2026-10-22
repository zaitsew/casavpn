import Foundation

/// Signs in to a 3x-ui panel the way its login page does, then makes an admin API token for the app.
///
/// 1. `GET <base>/csrf-token` gives the CSRF token and the `3x-ui` session cookie.
/// 2. `POST <base>/login` (form: username, password, twoFactorCode) with that cookie and `X-CSRF-Token`.
/// 3. `GET <base>/csrf-token` again, with the signed-in cookie.
/// 4. `POST <base>/panel/api/setting/apiTokens/create` makes the token `CasaVPN <device>`.
///
/// The app keeps the token and the URL and forgets the password. If step 4 is impossible, the signed-in
/// session is kept instead and `SignInResult.tokenProblem` says why.
public struct PanelSignIn: Sendable {
    public struct Result: Equatable, Sendable {
        public var settings: ConnectionSettings
        /// True when the app made its own API token. False when it kept the session.
        public var madeToken: Bool
        /// Why no token was made (only when `madeToken` is false).
        public var tokenProblem: String?
    }

    private let transport: any HTTPTransport
    private let deviceName: String

    public init(transport: any HTTPTransport = URLSessionTransport(), deviceName: String) {
        self.transport = transport
        self.deviceName = deviceName
    }

    /// The token name for this device: `CasaVPN <device name>`, at most 64 characters (the panel's limit).
    public static func tokenName(device: String, attempt: Int = 1) -> String {
        let cleaned = device.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "CasaVPN " + (cleaned.isEmpty ? "iPhone" : cleaned)
        let suffix = attempt > 1 ? " \(attempt)" : ""
        return String(base.prefix(64 - suffix.count)) + suffix
    }

    public func signIn(
        address: String, username: String, password: String, twoFactorCode: String = "",
        headers: [CustomHeader] = []
    ) async throws -> Result {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { throw PanelError.invalidRequest("Enter the panel user name.") }
        if password.isEmpty { throw PanelError.invalidRequest("Enter the panel password.") }
        for header in headers where !(header.name.isBlank && header.value.isBlank) {
            if let problem = header.validationError { throw PanelError.invalidRequest(problem) }
        }
        let cleanHeaders = headers.filter { !($0.name.isBlank && $0.value.isBlank) }
        let normalized: String
        do { normalized = try PanelAddress.normalize(address) } catch let problem as PanelAddress.Problem {
            throw PanelError.invalidRequest(problem.errorDescription ?? "")
        }
        guard let base = URL(string: normalized) else { throw PanelError.invalidRequest(PanelAddress.Problem.invalid.errorDescription ?? "") }

        // 1. A CSRF token and a session cookie.
        let first = try await fetchCSRF(base: base, headers: cleanHeaders, cookie: nil)
        guard var cookie = first.cookie else {
            throw PanelError.invalidRequest("The panel did not start a session. Check the address, including the base path.")
        }

        // 2. The login form.
        var fields = [("username", user), ("password", password)]
        let code = twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty { fields.append(("twoFactorCode", code)) }
        let login = try PanelRequest.make(
            base: base, path: "/login", method: "POST", credential: .session(cookie: cookie, csrf: first.token),
            headers: cleanHeaders, form: fields
        )
        let (loginData, loginResponse) = try await PanelRequest.send(login, transport: transport, sessionMode: false)
        let envelope = try? JSONDecoder().decode(PanelEnvelope<AnyDecodable>.self, from: loginData)
        guard let envelope else { throw PanelError.decoding }
        guard envelope.success else {
            let hint = code.isEmpty ? " If the account uses two-factor sign-in, enter the code." : ""
            throw PanelError.signInFailed((envelope.msg.flatMap { $0.isEmpty ? nil : $0 } ?? "Wrong user name or password.") + hint)
        }
        if let renewed = PanelWire.cookie(named: PanelClient.sessionCookieName, in: loginResponse) { cookie = renewed }

        // 3. The CSRF token of the signed-in session.
        let second = try await fetchCSRF(base: base, headers: cleanHeaders, cookie: cookie)
        if let renewed = second.cookie { cookie = renewed }
        let session = PanelCredential.session(cookie: cookie, csrf: second.token)

        var settings = ConnectionSettings(panelURL: normalized, panelUser: user, panelHeaders: cleanHeaders)

        // 4. The app's own token.
        do {
            let info = try await makeToken(base: base, session: session, headers: cleanHeaders)
            settings.panelToken = info.token
            settings.panelTokenID = info.id
            settings.panelTokenName = info.name
            return Result(settings: settings, madeToken: true, tokenProblem: nil)
        } catch let error as PanelError {
            // A network that fails now will fail again with the token: tell the person.
            switch error {
            case .unreachable, .tls, .refusedByProxy: throw error
            default: break
            }
            settings.panelSession = cookie
            settings.panelCSRF = second.token
            return Result(settings: settings, madeToken: false, tokenProblem: error.errorDescription)
        }
    }

    private func fetchCSRF(base: URL, headers: [CustomHeader], cookie: String?) async throws -> (token: String, cookie: String?) {
        let credential: PanelCredential? = cookie.map { .session(cookie: $0, csrf: "") }
        var request = try PanelRequest.make(base: base, path: "/csrf-token", method: "GET", credential: credential, headers: headers)
        request.setValue(nil, forHTTPHeaderField: "X-CSRF-Token")
        let (data, response) = try await PanelRequest.send(request, transport: transport, sessionMode: false)
        let envelope: PanelEnvelope<String>
        do { envelope = try JSONDecoder().decode(PanelEnvelope<String>.self, from: data) } catch { throw PanelError.notFound }
        guard envelope.success, let token = envelope.obj, !token.isEmpty else { throw PanelError.notFound }
        return (token, PanelWire.cookie(named: PanelClient.sessionCookieName, in: response) ?? cookie)
    }

    private struct CreateBody: Encodable {
        var name: String
        var scope = "admin"
        var expiresAt = 0
    }

    /// Creates the token. If the name is taken (an earlier install on this device), tries `... 2`, `... 3`.
    private func makeToken(base: URL, session: PanelCredential, headers: [CustomHeader]) async throws -> ApiTokenInfo {
        var lastError: PanelError = .decoding
        for attempt in 1...5 {
            let name = Self.tokenName(device: deviceName, attempt: attempt)
            let body = try JSONEncoder().encode(CreateBody(name: name))
            let request = try PanelRequest.make(
                base: base, path: "/panel/api/setting/apiTokens/create", method: "POST", credential: session,
                headers: headers, json: body
            )
            do {
                let data = try await PanelRequest.perform(request, transport: transport, sessionMode: true)
                let envelope = try JSONDecoder().decode(PanelEnvelope<ApiTokenInfo>.self, from: data)
                if envelope.success, let info = envelope.obj, !info.token.isEmpty { return info }
                let message = envelope.msg ?? ""
                lastError = .api(message)
                // "a token with that name already exists": try the next name; anything else stops.
                if !message.lowercased().contains("already exists") { throw lastError }
            } catch let error as PanelError {
                throw error
            } catch {
                throw PanelError.decoding
            }
        }
        throw lastError
    }
}
