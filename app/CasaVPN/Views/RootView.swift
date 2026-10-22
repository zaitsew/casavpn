import CasaKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            StatusView()
                .tabItem { Label("Status", systemImage: "checkmark.shield") }
                .tag(AppTab.status)
            ClientsView()
                .tabItem { Label("Clients", systemImage: "person.2") }
                .tag(AppTab.clients)
            AlertsView()
                .tabItem { Label("Alerts", systemImage: "bell") }
                .tag(AppTab.alerts)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onOpenURL { model.handleIncoming(url: $0) }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAll() } }
        }
        .alert(
            "Pair with this server?",
            isPresented: Binding(
                get: { model.pendingPairing != nil },
                set: { if !$0 { model.cancelPairing() } }
            ),
            presenting: model.pendingPairing
        ) { _ in
            Button("Pair") { model.confirmPairing() }
            Button("Cancel", role: .cancel) { model.cancelPairing() }
        } message: { pairing in
            Text(pairingSummary(pairing))
        }
    }

    private func pairingSummary(_ pairing: ConnectionSettings) -> String {
        let panel = pairing.panelBase?.host ?? "unknown"
        let relay = pairing.relayBase?.host ?? "unknown"
        return "This replaces the connection details of this app.\nPanel: \(panel)\nRelay: \(relay)"
    }
}
