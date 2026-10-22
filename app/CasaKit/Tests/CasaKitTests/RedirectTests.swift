import Foundation
import Testing
@testable import CasaKit

@Suite("Redirects")
struct RedirectTests {
    let origin = URL(string: "https://vpn.example.com:8443/secret-path/login")!

    @Test func followsARedirectInsideOneOrigin() {
        #expect(RedirectPolicy.allows(from: origin, to: URL(string: "https://vpn.example.com:8443/secret-path/login/")))
        #expect(RedirectPolicy.allows(from: origin, to: URL(string: "https://VPN.example.com:8443/other")))
        #expect(RedirectPolicy.allows(from: URL(string: "https://vpn.example.com/a"), to: URL(string: "https://vpn.example.com:443/b")))
    }

    @Test func refusesAnotherHostPortOrScheme() {
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "https://evil.example.net:8443/secret-path/login")))
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "https://vpn.example.com:9443/secret-path/login")))
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "http://vpn.example.com:8443/secret-path/login")))
        #expect(!RedirectPolicy.allows(from: origin, to: URL(string: "https://vpn.example.com.evil.example.net:8443/")))
        #expect(!RedirectPolicy.allows(from: origin, to: nil))
    }

    @Test func aRefusedRedirectIsAClearError() {
        for status in [301, 302, 307, 308] {
            let error = PanelWire.failure(status: status, data: Data(), contentType: nil, sessionMode: false)
            #expect(error == .redirected(status))
            #expect(error?.errorDescription?.contains("redirects to another server") == true)
        }
    }

    @Test func signInStopsAtARedirectFromLoginAndMakesNoToken() async {
        let csrf = FakeTransport.Reply.full(
            status: 200, body: #"{"success": true, "obj": "csrf-one"}"#,
            headers: ["Set-Cookie": "3x-ui=cookie-one; Path=/secret-path/; HttpOnly"]
        )
        let transport = FakeTransport(csrf, .full(status: 307, body: "", headers: ["Location": "https://evil.example.net/login"]))
        do {
            _ = try await PanelSignIn(transport: transport, deviceName: "Test Phone")
                .signIn(address: "https://vpn.example.com:8443/secret-path", username: "admin", password: "correct horse")
            Issue.record("sign-in should have failed")
        } catch {
            #expect(error as? PanelError == .redirected(307))
        }
        // Only the CSRF request and the login were sent; nothing went on to token creation.
        #expect(transport.requests.count == 2)
    }
}
