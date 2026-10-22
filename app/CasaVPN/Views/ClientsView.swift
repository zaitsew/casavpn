import CasaKit
import SwiftUI

struct ClientsView: View {
    @Environment(AppModel.self) private var model
    @State private var sharing: VPNClient?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if model.clientsState.isFailure || model.clientsState == .notConfigured {
                    Section { PanelStateNotice(state: model.clientsState) }
                }
                if model.clientsState == .loading && model.clients.isEmpty {
                    Section { ProgressView() }
                }
                if model.clientsState == .loaded && model.clients.isEmpty {
                    Section { StateNotice(symbol: "person.crop.circle.badge.questionmark", text: "The panel has no clients yet.") }
                }
                if !model.clients.isEmpty {
                    Section {
                        ForEach(model.clients) { client in
                            ClientRow(client: client, onShare: { sharing = client })
                        }
                    } footer: {
                        Text("\(model.clients.count) clients, \(model.onlineEmails.count) online")
                    }
                }
            }
            .navigationTitle("Clients")
            .refreshable { await model.refreshClients() }
            .sheet(item: $sharing) { client in ShareClientSheet(client: client) }
            .alert(
                "Could not change the client",
                isPresented: Binding(
                    get: { model.clientError != nil },
                    set: { if !$0 { model.clientError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.clientError ?? "")
            }
        }
    }
}

private struct ClientRow: View {
    @Environment(AppModel.self) private var model
    let client: VPNClient
    let onShare: () -> Void

    var body: some View {
        let expiry = ExpiryInfo.describe(expiryTime: client.expiryTime)
        let fraction = Format.trafficFraction(used: client.usedBytes, limit: client.limitBytes)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if model.isOnline(client) {
                        Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
                            .accessibilityLabel("Online now")
                    }
                    Text(client.email).font(.headline)
                }
                Text(Format.traffic(used: client.usedBytes, limit: client.limitBytes))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(fraction >= 1 ? .red : fraction >= 0.9 ? .orange : .accentColor)
                }
                Text(expiry.text)
                    .font(.footnote)
                    .foregroundStyle(expiry.isUrgent ? Color.red : Color.secondary)
                if model.isOnline(client) {
                    Text("Online now").font(.footnote).foregroundStyle(.green)
                }
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { client.enable },
                set: { value in Task { await model.setClient(client, enabled: value) } }
            ))
            .labelsHidden()
            .disabled(model.busyClients.contains(client.email))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onShare)
        .swipeActions(edge: .trailing) {
            Button("Share", systemImage: "square.and.arrow.up", action: onShare).tint(.accentColor)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Share subscription link", onShare)
    }
}

/// The subscription link as text, a QR code and the iOS share sheet.
struct ShareClientSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let client: VPNClient
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let link = model.subscriptionLink(for: client) {
                        if let image = QRCode.cgImage(for: link) {
                            Image(decorative: image, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 280)
                                .padding(12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("QR code of the subscription link")
                        }
                        Text(link)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            ShareLink(item: link) {
                                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                UIPasteboard.general.string = link
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                    } else {
                        StateNotice(
                            symbol: "link.badge.plus",
                            text: client.subId.isEmpty
                                ? "This client has no subscription id."
                                : "Set the subscription base URL in Settings to share a link."
                        )
                    }
                }
                .padding()
            }
            .navigationTitle(client.email)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}
