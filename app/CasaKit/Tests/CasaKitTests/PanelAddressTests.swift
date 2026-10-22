import Foundation
import Testing
@testable import CasaKit

@Suite("PanelAddress")
struct PanelAddressTests {
    @Test func keepsTheBasePathAndPort() throws {
        #expect(try PanelAddress.normalize("https://vpn.example.com:8443/secret-path/") == "https://vpn.example.com:8443/secret-path")
    }

    @Test func addsHTTPSWhenTheSchemeIsMissing() throws {
        #expect(try PanelAddress.normalize("vpn.example.com:8443/secret-path") == "https://vpn.example.com:8443/secret-path")
    }

    @Test func cutsWhatTheBrowserAddressBarAddsAfterTheBasePath() throws {
        #expect(try PanelAddress.normalize("https://vpn.example.com:8443/secret-path/panel/inbounds") == "https://vpn.example.com:8443/secret-path")
        #expect(try PanelAddress.normalize("https://vpn.example.com:8443/secret-path/panel/") == "https://vpn.example.com:8443/secret-path")
        #expect(try PanelAddress.normalize("https://vpn.example.com:8443/secret-path/login") == "https://vpn.example.com:8443/secret-path")
        #expect(try PanelAddress.normalize("https://vpn.example.com/panel") == "https://vpn.example.com")
    }

    @Test func dropsQueryFragmentAndCredentials() throws {
        #expect(try PanelAddress.normalize("https://user:pw@vpn.example.com:8443/p/?a=1#x") == "https://vpn.example.com:8443/p")
    }

    @Test func refusesPlainHTTPAndEmptyInput() {
        #expect(throws: PanelAddress.Problem.notHTTPS) { try PanelAddress.normalize("http://vpn.example.com:8443/p") }
        #expect(throws: PanelAddress.Problem.empty) { try PanelAddress.normalize("   ") }
        #expect(throws: PanelAddress.Problem.invalid) { try PanelAddress.normalize("not a url at all") }
        #expect(throws: PanelAddress.Problem.invalid) { try PanelAddress.normalize("ftp://vpn.example.com") }
    }
}
