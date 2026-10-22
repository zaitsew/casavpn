import CasaKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ConnectionSettings.empty
    @State private var loaded = false
    @State private var showScanner = false
    @State private var pairingError: String?
    @State private var confirmSignOut = false
    @State private var isSigningOut = false
    @State private var showHeaders = false
    @State private var headerDraft: [CustomHeader] = []

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                if !model.isDemo {
                    pairingSection
                    relaySection
                    subscriptionSection
                    saveSection
                }
                pushSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear { loadDraftOnce() }
            .onChange(of: model.settings) { _, new in draft = new }
            .sheet(isPresented: $showScanner) { scannerSheet }
            .sheet(isPresented: $showHeaders, onDismiss: {
                if headerDraft != model.settings.panelHeaders { model.saveHeaders(headerDraft) }
            }) { HeadersEditor(headers: $headerDraft) }
            .confirmationDialog("Sign out of the panel?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        isSigningOut = true
                        await model.signOut()
                        isSigningOut = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(model.settings.ownsPanelToken
                     ? "The app deletes its token \"\(model.settings.panelTokenName)\" on the panel and forgets the server."
                     : "The app forgets the server and the credentials saved for it.")
            }
            .alert(
                "Could not read the link",
                isPresented: Binding(get: { pairingError != nil }, set: { if !$0 { pairingError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(pairingError ?? "")
            }
        }
    }

    private func loadDraftOnce() {
        guard !loaded else { return }
        draft = model.settings
        loaded = true
    }

    private var isDirty: Bool { draft.normalized() != model.settings }

    // MARK: Sections

    private var pairingSection: some View {
        Section {
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    if let error = model.proposePairing(from: text) { pairingError = error }
                }
            }
            .buttonBorderShape(.roundedRectangle)
            Button {
                showScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("Pair with a code")
        } footer: {
            Text("Run casavpn-pair on the server to show a QR code, or paste the casavpn:// link it prints.")
        }
    }

    private var connectionSection: some View {
        Section {
            if model.isDemo {
                Label("Demo mode. Nothing leaves this iPhone.", systemImage: "play.rectangle")
                Button("Exit demo") { model.exitDemo() }
            } else if model.settings.hasPanel {
                LabeledContent("Server", value: displayHost(model.settings.panelURL))
                if !model.settings.panelUser.isEmpty {
                    LabeledContent("Signed in as", value: model.settings.panelUser)
                }
                LabeledContent("Access") {
                    Text(accessText).multilineTextAlignment(.trailing)
                }
                Button {
                    headerDraft = model.settings.panelHeaders
                    showHeaders = true
                } label: {
                    LabeledContent("Request headers", value: model.settings.panelHeaders.isEmpty ? "None" : "\(model.settings.panelHeaders.count)")
                }
                .foregroundStyle(.primary)
                Button(role: .destructive) { confirmSignOut = true } label: {
                    HStack {
                        Text("Sign out")
                        if isSigningOut { Spacer(); ProgressView() }
                    }
                }
                .disabled(isSigningOut)
            } else {
                Text("Not signed in to a panel.").foregroundStyle(.secondary)
                Button { model.showReauth = true } label: { Label("Sign in to the panel", systemImage: "person.badge.key") }
                DisclosureGroup("Use an API token instead") {
                    urlField("https://vpn.example.com:8443/<base path>", text: $draft.panelURL)
                    SecureField("API token", text: $draft.panelToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            if let note = model.signOutNote {
                Text(note).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Panel")
        } footer: {
            if model.isDemo {
                Text("The demo shows sample data from a fictional server.")
            } else if model.settings.hasPanel {
                footer(for: model.settings.panelURL, fallback: "The app keeps an API token, not your password. Extra headers go to a proxy in front of the panel, such as Cloudflare Access.")
            } else {
                footer(for: draft.panelURL, fallback: "An admin token unlocks everything. A monitor token shows the Status tab only.")
            }
        }
    }

    private var accessText: String {
        let s = model.settings
        if s.ownsPanelToken { return "API token \"\(s.panelTokenName)\"" }
        if !s.panelToken.isEmpty { return "API token you pasted" }
        return "Session (sign in again when it expires)"
    }

    private func displayHost(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        if let port = URL(string: url)?.port { return "\(host):\(port)" }
        return host
    }

    private var relaySection: some View {
        Section {
            urlField("https://casavpn-monitor.example.workers.dev", text: $draft.relayURL)
            SecureField("App token", text: $draft.relayToken)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Relay")
        } footer: {
            footer(for: draft.relayURL, fallback: "The relay keeps the alert history and sends the push notifications.")
        }
    }

    private var subscriptionSection: some View {
        Section {
            urlField("https://vpn.example.com:8443/sub/", text: $draft.subURL)
        } header: {
            Text("Subscription base URL")
        } footer: {
            footer(for: draft.subURL, fallback: "The app adds the client's subscription id to this address when you share a link.")
        }
    }

    private var saveSection: some View {
        Section {
            Button("Save") { model.save(draft) }
                .disabled(!isDirty)
            if let error = model.saveError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Text("The details are kept in this iPhone's Keychain and sent only to the servers above.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var pushSection: some View {
        Section {
            Toggle("Push notifications", isOn: Binding(
                get: { model.pushEnabled },
                set: { value in Task { await model.setPushEnabled(value) } }
            ))
            .disabled(!model.settings.hasRelay || model.isDemo)
            if let message = model.pushMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
            if model.pushAuthorization == .denied {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button {
                Task { if model.isDemo { await model.sendDemoTestAlert() } else { await model.sendTestAlert() } }
            } label: {
                HStack {
                    Text("Send test alert")
                    if model.isSendingTest { Spacer(); ProgressView() }
                }
            }
            .disabled((!model.settings.hasRelay && !model.isDemo) || model.isSendingTest)
            if let message = model.testMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text(model.isDemo
                 ? "The demo posts a notification on this iPhone only."
                 : model.settings.hasRelay
                 ? "Critical alerts are delivered as time-sensitive notifications."
                 : "Set up the relay first. Critical alerts are delivered as time-sensitive notifications.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.versionText)
        } header: {
            Text("About")
        } footer: {
            Text("No analytics and no third-party code. The app talks only to the panel and the relay you set up.")
        }
    }

    // MARK: Pieces

    private func urlField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .keyboardType(.URL)
            .textContentType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    @ViewBuilder private func footer(for url: String, fallback: String) -> some View {
        if !url.isBlank, ConnectionSettings.httpsURL(url) == nil {
            Text("The address must start with https://").foregroundStyle(.red)
        } else {
            Text(fallback)
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            Group {
                if QRScannerView.isAvailable {
                    QRScannerView { text in
                        showScanner = false
                        if let error = model.proposePairing(from: text) { pairingError = error }
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "The scanner is not available",
                        systemImage: "camera.metering.unknown",
                        description: Text("Allow camera access for CasaVPN in the iOS Settings app, or paste the pairing link instead.")
                    )
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } }
            }
        }
    }
}

private extension Bundle {
    var versionText: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
