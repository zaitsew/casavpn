import CasaKit
import SwiftUI

struct AlertsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.alertPath) {
            List {
                if model.relayState.isFailure || model.relayState == .notConfigured {
                    Section { RelayStateNotice(state: model.relayState) }
                }
                if model.relayState == .loading && model.alerts.isEmpty {
                    Section { ProgressView() }
                }
                if model.relayState == .loaded && model.alerts.isEmpty {
                    Section { StateNotice(symbol: "bell.slash", text: "No alerts yet. Use Settings to send a test alert.") }
                }
                if !model.alerts.isEmpty {
                    Section {
                        ForEach(model.alerts) { alert in
                            NavigationLink(value: alert.id) { AlertRow(alert: alert) }
                        }
                    }
                }
            }
            .navigationTitle("Alerts")
            .navigationDestination(for: String.self) { id in AlertDetailView(alertId: id) }
            .refreshable { await model.refreshRelay() }
        }
    }
}

private struct AlertRow: View {
    let alert: VPNAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.severity.symbol)
                .foregroundStyle(alert.severity.color)
                .font(.title3)
                .frame(width: 28)
                .accessibilityLabel(alert.severity.label)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(.headline)
                Text(alert.body).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                Text(alert.at.relativeDescription).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct AlertDetailView: View {
    @Environment(AppModel.self) private var model
    let alertId: String

    var body: some View {
        Group {
            if let alert = model.alert(id: alertId) {
                List {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: alert.severity.symbol)
                                .foregroundStyle(alert.severity.color).font(.title2)
                            Text(alert.severity.label).font(.headline).foregroundStyle(alert.severity.color)
                        }
                        Text(alert.title).font(.title3.weight(.semibold))
                        Text(alert.body)
                    }
                    Section {
                        LabeledContent("When", value: alert.at.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("Kind", value: alert.kind)
                        LabeledContent("Source", value: alert.source)
                    }
                }
            } else if model.relayState == .loading || model.relayState == .idle {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Alert not found",
                    systemImage: "bell.slash",
                    description: Text("It is no longer in the relay's history, which keeps the newest 100.")
                )
            }
        }
        .navigationTitle("Alert")
        .navigationBarTitleDisplayMode(.inline)
    }
}
