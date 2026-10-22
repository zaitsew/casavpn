import CasaKit
import SwiftUI

struct StatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                vpnSection
                serverSection
            }
            .navigationTitle("Status")
            .refreshable { await model.refreshAll() }
        }
    }

    // MARK: VPN (relay)

    @ViewBuilder private var vpnSection: some View {
        Section("VPN") {
            if let monitor = model.monitor {
                HStack {
                    Image(systemName: monitorSymbol(monitor.status))
                        .foregroundStyle(monitorColor(monitor.status))
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitorTitle(monitor.status)).font(.headline)
                        if let since = monitor.since, monitor.status != .unknown {
                            Text("Since \(since.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                if let ip = monitor.ip { LabeledContent("Public IP", value: ip) }
                if let target = monitor.target { LabeledContent("Checked", value: target) }
                if let last = monitor.lastCheck { LabeledContent("Last check", value: last.relativeDescription) }
            } else if model.relayState == .loading || model.relayState == .idle {
                ProgressView()
            }
            RelayStateNotice(state: model.relayState)
        }
    }

    private func monitorTitle(_ status: MonitorStatus) -> String {
        switch status {
        case .up: "The VPN is up"
        case .down: "The VPN is down"
        case .unknown: "Not checked yet"
        }
    }

    private func monitorSymbol(_ status: MonitorStatus) -> String {
        switch status {
        case .up: "checkmark.circle.fill"
        case .down: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private func monitorColor(_ status: MonitorStatus) -> Color {
        switch status {
        case .up: .green
        case .down: .red
        case .unknown: .secondary
        }
    }

    // MARK: Server (panel)

    @ViewBuilder private var serverSection: some View {
        Section("Server") {
            if let status = model.serverStatus {
                LabeledContent("Xray") {
                    HStack(spacing: 6) {
                        Image(systemName: xrayRunning(status) ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(xrayRunning(status) ? .green : .red)
                        Text(xrayText(status))
                    }
                }
                if status.xray.state == .error, !status.xray.errorMsg.isEmpty {
                    Text(status.xray.errorMsg).font(.footnote).foregroundStyle(.red)
                }
                usageRow("CPU", fraction: status.cpu / 100, detail: Format.percent(status.cpu))
                usageRow("Memory", fraction: status.mem.fraction, detail: "\(Format.bytes(status.mem.current)) of \(Format.bytes(status.mem.total))")
                usageRow("Disk", fraction: status.disk.fraction, detail: "\(Format.bytes(status.disk.current)) of \(Format.bytes(status.disk.total))")
                LabeledContent("Uptime", value: Format.uptime(seconds: status.uptime))
                if !status.panelVersion.isEmpty { LabeledContent("Panel", value: status.panelVersion) }
            } else if model.statusState == .loading || model.statusState == .idle {
                ProgressView()
            }
            PanelStateNotice(state: model.statusState)
        }
    }

    private func xrayRunning(_ status: ServerStatus) -> Bool { status.xray.state == .running }

    private func xrayText(_ status: ServerStatus) -> String {
        let state: String
        switch status.xray.state {
        case .running: state = "Running"
        case .stop: state = "Stopped"
        case .error: state = "Error"
        case .unknown: state = "Unknown"
        }
        return status.xray.version.isEmpty ? state : "\(state), \(status.xray.version)"
    }

    private func usageRow(_ title: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(1, max(0, fraction)))
                .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}
