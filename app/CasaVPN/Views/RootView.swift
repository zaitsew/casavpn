import CasaKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.needsSignIn {
                SignInView()
            } else {
                tabs
            }
        }
        .onOpenURL { model.handleIncoming(url: $0) }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAll() } }
        }
        .sheet(isPresented: Binding(get: { model.showReauth }, set: { model.showReauth = $0 })) {
            SignInView(isReauth: true)
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

    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.selectedTab) {
            StatusView()
                .tabItem { Label("Status", systemImage: "checkmark.shield") }
                .tag(AppTab.status)
            InboundsView()
                .tabItem { Label("Inbounds", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(AppTab.inbounds)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isDemo { DemoBanner() }
        }
        .alert(
            "Could not finish",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private func pairingSummary(_ pairing: ConnectionSettings) -> String {
        let panel = pairing.panelBase?.host ?? "unknown"
        let relay = pairing.relayBase?.host ?? "unknown"
        return "This replaces the connection details of this app.\nPanel: \(panel)\nRelay: \(relay)"
    }
}

/// Shown above every tab while the demo runs.
struct DemoBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.circle.fill")
            VStack(alignment: .leading, spacing: 0) {
                Text("Demo").font(.subheadline.weight(.semibold))
                Text("Sample data. Nothing leaves this iPhone.").font(.caption)
            }
            Spacer()
            Button("Exit demo") { model.exitDemo() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(Color.orange.gradient)
        .tint(.white)
        .accessibilityElement(children: .contain)
    }
}
