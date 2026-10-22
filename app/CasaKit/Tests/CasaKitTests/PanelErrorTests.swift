import Foundation
import Testing
@testable import CasaKit

@Suite("Panel errors")
struct PanelErrorTests {
    func client(_ reply: FakeTransport.Reply, headers: [CustomHeader] = []) -> PanelClient {
        PanelClient(baseURL: panelURL, credential: .bearer("t"), headers: headers, transport: FakeTransport(reply))
    }

    func failure(_ reply: FakeTransport.Reply) async -> PanelError? {
        do { _ = try await client(reply).serverStatus(); return nil } catch { return error as? PanelError }
    }

    @Test func anHTMLForbiddenPageIsARefusedNetworkNotATokenProblem() async throws {
        let error = try #require(await failure(.response(status: 403, body: "<html><body><h1>403 Forbidden</h1><hr>nginx</body></html>")))
        #expect(error == .refusedByProxy(403))
        #expect(error.kind == .refused)
        let text = try #require(error.errorDescription)
        #expect(text.hasPrefix("The server refused this network. The panel is reachable from your home network or through your VPN"))
        #expect(text.contains("docs/APP.md"))
        #expect(!text.lowercased().contains("token"))
    }

    @Test func anHTMLNotFoundPageIsARefusedNetworkToo() async {
        #expect(await failure(.response(status: 404, body: "<!DOCTYPE html><html><title>Not Found</title></html>")) == .refusedByProxy(404))
    }

    @Test func aLoginWallThatAnswers200WithHTMLIsRefused() async {
        #expect(await failure(.response(status: 200, body: "<html><form action=\"/login\"></form></html>")) == .refusedByProxy(200))
    }

    @Test func anHTMLContentTypeAloneIsEnough() async {
        let reply = FakeTransport.Reply.full(status: 403, body: "Forbidden", headers: ["Content-Type": "text/html; charset=utf-8"])
        #expect(await failure(reply) == .refusedByProxy(403))
    }

    @Test func aJSONForbiddenIsAScopeProblem() async throws {
        let error = try #require(await failure(.response(status: 403, body: #"{"success": false, "msg": "this API token is not permitted to access this endpoint"}"#)))
        #expect(error == .forbidden("this API token is not permitted to access this endpoint"))
        #expect(error.errorDescription?.contains("not allowed") == true)
    }

    @Test func anEmptyForbiddenWithATokenComesFromTheNetwork() async {
        #expect(await failure(.response(status: 403, body: "")) == .refusedByProxy(403))
    }

    @Test func anEmptyForbiddenWithASessionIsAnExpiredSession() async {
        let session = PanelClient(
            baseURL: panelURL, credential: .session(cookie: "c", csrf: "x"), transport: FakeTransport(.response(status: 403, body: ""))
        )
        do { _ = try await session.serverStatus(); Issue.record("expected an error") } catch {
            #expect(error as? PanelError == .unauthorized)
        }
    }

    @Test func a401WithoutAPageMeansSignInAgain() async throws {
        let error = try #require(await failure(.response(status: 401, body: #"{"success": false, "msg": "unauthorized"}"#)))
        #expect(error == .unauthorized)
        #expect(error.kind == .unauthorized)
    }

    @Test func a401PageFromAGatewayIsARefusedNetwork() async {
        #expect(await failure(.response(status: 401, body: "<html>Sign in with your identity provider</html>")) == .refusedByProxy(401))
    }

    @Test func certificateProblemsAreTLSNotUnreachable() async {
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot] {
            #expect(await failure(.failure(code)) == .tls)
        }
        #expect(PanelError.tls.kind == .tls)
        #expect(PanelError.tls.errorDescription?.contains("certificate") == true)
    }

    @Test func timeoutsAndNoRouteAreUnreachable() async {
        for code in [URLError.Code.timedOut, .cannotConnectToHost, .notConnectedToInternet, .cannotFindHost] {
            #expect(await failure(.failure(code)) == .unreachable)
        }
    }

    @Test func aServerErrorIsReportedWithItsStatus() async {
        #expect(await failure(.response(status: 502, body: "bad gateway")) == .http(502))
    }
}
