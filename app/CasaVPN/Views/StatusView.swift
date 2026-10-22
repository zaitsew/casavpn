import CasaKit
import SwiftUI

struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRestart = false
    @State private var confirmStop = false
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            List {
                vpnSection
                serverSection
                if let status = model.serverStatus {
                    resourcesSection(status)
                    networkSection(status)
                    xraySection(status)
                } else {
                    Section { PanelStateNotice(state: model.statusState) }
                }
            }
            .navigationTitle("Status")
            .refreshable { await model.refreshAll() }
            .confirmationDialog("Restart Xray?", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button("Restart Xray", role: .destructive) { run { await model.restartXray() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Connected devices drop for a few seconds and reconnect.")
            }
            .confirmationDialog("Stop Xray?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Xray", role: .destructive) { run { await model.stopXray() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Nobody can use the VPN until you start it again.")
            }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isBusy = true
        Task {
            await work()
            isBusy = false
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
        if model.serverStatus == nil, model.statusState == .loading || model.statusState == .idle {
            Section("Server") { ProgressView() }
        }
    }

    private func resourcesSection(_ status: ServerStatus) -> some View {
        Section("Server") {
            usageRow("CPU", fraction: status.cpu / 100,
                     detail: status.cpuCores > 0 ? "\(Format.percent(status.cpu)) of \(status.cpuCores) cores" : Format.percent(status.cpu))
            usageRow("Memory", fraction: status.mem.fraction, detail: "\(Format.bytes(status.mem.current)) of \(Format.bytes(status.mem.total))")
            if status.swap.total > 0 {
                usageRow("Swap", fraction: status.swap.fraction, detail: "\(Format.bytes(status.swap.current)) of \(Format.bytes(status.swap.total))")
            }
            usageRow("Disk", fraction: status.disk.fraction, detail: "\(Format.bytes(status.disk.current)) of \(Format.bytes(status.disk.total))")
            if !status.loads.isEmpty {
                LabeledContent("Load") {
                    Text(status.loads.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  ")).monospacedDigit()
                }
            }
            LabeledContent("Uptime", value: Format.uptime(seconds: status.uptime))
            if !status.panelVersion.isEmpty { LabeledContent("Panel version", value: status.panelVersion) }
            if let ip = status.publicIPv4 { LabeledContent("Public IPv4", value: ip) }
        }
    }

    private func networkSection(_ status: ServerStatus) -> some View {
        Section("Network") {
            LabeledContent("Upload") {
                Label("\(Format.bytes(status.netUp))/s", systemImage: "arrow.up").monospacedDigit()
            }
            LabeledContent("Download") {
                Label("\(Format.bytes(status.netDown))/s", systemImage: "arrow.down").monospacedDigit()
            }
            LabeledContent("Sent since boot", value: Format.bytes(status.netSent))
            LabeledContent("Received since boot", value: Format.bytes(status.netReceived))
            LabeledContent("Connections", value: "\(status.tcpCount) TCP, \(status.udpCount) UDP")
        }
    }

    private func xraySection(_ status: ServerStatus) -> some View {
        Section {
            LabeledContent("State") {
                HStack(spacing: 6) {
                    Image(systemName: xrayRunning(status) ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(xrayRunning(status) ? .green : .red)
                    Text(xrayText(status))
                }
            }
            if status.xray.state == .error, !status.xray.errorMsg.isEmpty {
                Text(status.xray.errorMsg).font(.footnote).foregroundStyle(.red)
            }
            if status.xray.state == .running {
                Button(role: .destructive) { confirmRestart = true } label: {
                    Label("Restart Xray", systemImage: "arrow.clockwise")
                }
                .disabled(isBusy)
                Button(role: .destructive) { confirmStop = true } label: {
                    Label("Stop Xray", systemImage: "stop.circle")
                }
                .disabled(isBusy)
            } else {
                Button { run { await model.restartXray() } } label: {
                    Label("Start Xray", systemImage: "play.circle")
                }
                .disabled(isBusy)
            }
            NavigationLink {
                XrayLogView()
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
        } header: {
            Text("Xray")
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
