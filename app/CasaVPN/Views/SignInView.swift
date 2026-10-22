import CasaKit
import SwiftUI

/// The first screen, like the 3x-ui login page: server address, user name, password and an optional 2FA code.
/// The app uses the password once, to make its own API token, and does not keep it.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// True when shown as a sheet because the saved sign-in stopped working.
    var isReauth = false

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var twoFactor = ""
    @State private var headers: [CustomHeader] = []
    @State private var showHeaders = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var notice: String?
    @State private var showScanner = false
    @State private var pairingError: String?
    @FocusState private var focus: Field?

    private enum Field { case address, username, password, code }

    var body: some View {
        NavigationStack {
            Form {
                if let note = model.signOutNote { signOutNoteSection(note) }
                headerSection
                accountSection
                actionSection
                if !isReauth { alternativesSection }
            }
            .navigationTitle(isReauth ? "Sign in again" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isReauth {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancelSignIn(); dismiss() } }
                }
            }
            .onAppear(perform: prefill)
            // Swiping the sheet away would leave sign-in running; Cancel is the one way out.
            .interactiveDismissDisabled(isReauth)
            .sheet(isPresented: $showHeaders) { HeadersEditor(headers: $headers) }
            .sheet(isPresented: $showScanner) { scannerSheet }
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

    // MARK: Sections

    /// What Sign out could not finish. It stays until the person dismisses it.
    private func signOutNoteSection(_ note: String) -> some View {
        Section {
            StateNotice(symbol: "exclamationmark.triangle", text: note, tint: .orange)
            Button("Dismiss") { model.signOutNote = nil }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("CasaVPN")
                    .font(.largeTitle.bold())
                Text("Manage your own 3x-ui server from your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private var accountSection: some View {
        Section {
            TextField("https://vpn.example.com:8443/path", text: $address)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .address)
                .submitLabel(.next)
                .onSubmit { focus = .username }
                .accessibilityLabel("Server address")
            TextField("User name", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = .password }
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.next)
                .onSubmit { focus = .code }
            TextField("2FA code (only if you use one)", text: $twoFactor)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focus, equals: .code)
            Button {
                showHeaders = true
            } label: {
                HStack {
                    Label("Extra request headers", systemImage: "list.bullet.rectangle")
                    Spacer()
                    if !headers.isEmpty { Text("\(headers.count)").foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Your panel")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Enter the address you open in the browser, with its base path, and the admin account you sign in with there.")
                Text(PanelMessages.noSignUp)
                Link("Set up a server: read the quick start", destination: DocsLink.quickstart)
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    Spacer()
                    if isWorking { ProgressView() } else { Text("Sign in").bold() }
                    Spacer()
                }
            }
            .disabled(!canSubmit)
            if !isReauth {
                Button {
                    model.startDemo()
                } label: {
                    HStack {
                        Spacer()
                        Label("Try the demo", systemImage: "play.circle")
                        Spacer()
                    }
                }
            }
            if let message {
                StateNotice(symbol: "exclamationmark.triangle", text: message, tint: .red)
                if message.contains("docs/APP.md") {
                    Link("Reaching the panel from outside", destination: DocsLink.remoteAccess).font(.footnote)
                }
            }
            if let notice {
                StateNotice(symbol: "info.circle", text: notice, tint: .blue)
            }
        } footer: {
            Text("The app makes its own API token on the panel and keeps only that token in this iPhone's Keychain. It does not keep your password. The demo shows a fictional server with sample data and needs no network.")
        }
    }

    private var alternativesSection: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("Pair with a code: scan QR", systemImage: "qrcode.viewfinder")
            }
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    if let error = model.proposePairing(from: text) { pairingError = error }
                }
            }
            .buttonBorderShape(.roundedRectangle)
            if model.settings.hasRelay {
                Button("Continue with alerts only") { model.skipSignIn() }
            }
        } header: {
            Text("Other ways in")
        } footer: {
            Text("Run casavpn-pair on the server for the QR code or the casavpn:// link.")
        }
    }

    // MARK: Actions

    private var canSubmit: Bool {
        !isWorking && !address.isBlank && !username.isBlank && !password.isEmpty
    }

    private func prefill() {
        guard address.isEmpty else { return }
        address = model.settings.panelURL
        username = model.settings.panelUser
        headers = model.settings.panelHeaders
        // The first screen opens without the keyboard, so the demo and pairing buttons stay in view.
        if isReauth { focus = .password }
    }

    private func signIn() async {
        focus = nil
        isWorking = true
        message = nil
        notice = nil
        defer { isWorking = false }
        do {
            let result = try await model.signIn(
                address: address, username: username, password: password, twoFactor: twoFactor, headers: headers
            )
            password = ""
            twoFactor = ""
            if !result.madeToken {
                notice = "Signed in, but the panel did not allow a token (\(result.tokenProblem ?? "unknown reason")). "
                    + "The app keeps this session and asks for your password again when it expires."
            }
            if isReauth { dismiss() }
        } catch {
            message = error.panelMessage
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

/// Edits the extra headers sent with every panel request: for a proxy in front of the panel,
/// such as the service token of Cloudflare Access.
struct HeadersEditor: View {
    private struct Row: Identifiable {
        let id = UUID()
        var header: CustomHeader
        var isEmpty: Bool { header.name.isBlank && header.value.isBlank }
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var headers: [CustomHeader]
    @State private var rows: [Row] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Header name", text: $row.header.name)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            SecureField("Value", text: $row.header.value)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if !row.isEmpty, let problem = row.header.validationError {
                                Text(problem).font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                    .onDelete { rows.remove(atOffsets: $0) }
                    Button {
                        rows.append(Row(header: CustomHeader(name: "", value: "")))
                    } label: {
                        Label("Add header", systemImage: "plus")
                    }
                    Button {
                        rows = [
                            Row(header: CustomHeader(name: "CF-Access-Client-Id", value: "")),
                            Row(header: CustomHeader(name: "CF-Access-Client-Secret", value: "")),
                        ]
                    } label: {
                        Label("Use a Cloudflare Access service token", systemImage: "cloud")
                    }
                } footer: {
                    Text("Sent with every request to the panel. Values are kept in the Keychain. Authorization, Cookie and other headers the app sets itself cannot be replaced.")
                }
            }
            .navigationTitle("Request headers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        headers = rows.filter { !$0.isEmpty }.map(\.header)
                        dismiss()
                    }
                    .disabled(rows.contains { !$0.isEmpty && $0.header.validationError != nil })
                }
            }
            .onAppear { rows = headers.map { Row(header: $0) } }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
