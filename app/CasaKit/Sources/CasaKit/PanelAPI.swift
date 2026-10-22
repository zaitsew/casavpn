import Foundation

/// Everything the app asks of a 3x-ui panel. `PanelClient` talks to a real panel;
/// `DemoPanel` answers from sample data held in memory.
public protocol PanelAPI: Sendable {
    // Status and Xray
    func serverStatus() async throws -> ServerStatus
    /// Restarts Xray; also the way to start it when it is stopped.
    func restartXray() async throws
    func stopXray() async throws
    /// The newest `count` lines of Xray's access log that contain `filter`.
    func xrayLog(count: Int, filter: String) async throws -> [XrayLogEntry]
    /// The newest `count` lines of the panel's own log at `level` (debug, info, notice, warning, error).
    func panelLog(count: Int, level: String) async throws -> [String]

    // Inbounds
    func inbounds() async throws -> [Inbound]
    func inbound(id: Int) async throws -> InboundDetail
    func setInboundEnabled(id: Int, enabled: Bool) async throws
    func resetInboundTraffic(id: Int) async throws
    /// Adds the inbound (`draft.inboundId == nil`) or updates it.
    func saveInbound(_ draft: RealityInboundDraft) async throws
    func deleteInbound(id: Int) async throws
    func newRealityKeyPair() async throws -> RealityKeyPair

    // Clients
    func clients() async throws -> ClientsSnapshot
    func client(email: String) async throws -> ClientDetail
    /// Adds the client (`draft.originalEmail == nil`) or updates it.
    func saveClient(_ draft: ClientDraft) async throws
    func setClientEnabled(email: String, enabled: Bool) async throws
    func resetClientTraffic(email: String) async throws
    func deleteClient(email: String) async throws
    /// The `vless://` (and other protocol) links of the client, one per inbound.
    func clientLinks(email: String) async throws -> [String]
    /// The subscription base the panel advertises (`https://host:port/sub/`), or nil when subscriptions are off.
    func subscriptionBase() async throws -> String?
}
