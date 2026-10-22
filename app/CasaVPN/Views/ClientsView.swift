import CasaKit
import SwiftUI

struct ClientsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showNew = false
    @State private var sharing: VPNClient?

    private var shown: [VPNClient] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.clients }
        return model.clients.filter {
            $0.email.localizedCaseInsensitiveContains(query) || $0.comment.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.clientsState.isFailure || model.clientsState == .notConfigured {
                    Section { PanelStateNotice(state: model.clientsState) }
                }
                if model.clientsState == .loading && model.clients.isEmpty {
                    Section { ProgressView() }
                }
                if model.clientsState == .loaded && model.clients.isEmpty {
                    Section {
                        StateNotice(symbol: "person.crop.circle.badge.questionmark", text: "The panel has no clients yet. Tap + to add one.")
                    }
                }
                if !model.clients.isEmpty {
                    Section {
                        ForEach(shown) { client in
                            NavigationLink(value: client.email) {
                                ClientRow(client: client, onShare: { sharing = client })
                            }
                        }
                        if shown.isEmpty {
                            Text("No client matches \"\(search)\".").foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("\(model.clients.count) clients, \(model.onlineEmails.count) online")
                    }
                }
            }
            .navigationTitle("Clients")
            .navigationDestination(for: String.self) { ClientDetailView(email: $0) }
            .searchable(text: $search, prompt: "Search clients")
            .refreshable { await model.refreshClients(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Label("Add client", systemImage: "plus") }
                        .disabled(!model.hasPanelAccess)
                }
            }
            .sheet(isPresented: $showNew) { ClientEditorView(editing: nil) }
            .sheet(item: $sharing) { client in ShareClientSheet(client: client) }
        }
    }
}

private struct ClientRow: View {
    @Environment(AppModel.self) private var model
    let client: VPNClient
    let onShare: () -> Void

    var body: some View {
        let expiry = ExpiryInfo.describe(expiryTime: client.expiryTime)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if model.isOnline(client) {
                        Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
                            .accessibilityLabel("Online now")
                    }
                    Text(client.email).font(.headline)
                }
                TrafficMeter(used: client.usedBytes, limit: client.limitBytes)
                Text(expiry.text)
                    .font(.footnote)
                    .foregroundStyle(expiry.isUrgent ? Color.red : Color.secondary)
                if model.isOnline(client) {
                    Text("Online now").font(.footnote).foregroundStyle(.green)
                } else if let last = lastOnlineText(client) {
                    Text(last).font(.footnote).foregroundStyle(.secondary)
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
        .swipeActions(edge: .trailing) {
            Button("Share", systemImage: "square.and.arrow.up", action: onShare).tint(.accentColor)
        }
        .accessibilityAction(named: "Share links", onShare)
    }
}

func lastOnlineText(_ client: VPNClient) -> String? {
    guard let last = client.traffic?.lastOnline, last > 0 else { return nil }
    return "Last online " + Date(timeIntervalSince1970: Double(last) / 1000).relativeDescription
}

struct ClientDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let email: String
    @State private var detail: ClientDetail?
    @State private var loadError: String?
    @State private var showEdit = false
    @State private var showShare = false
    @State private var confirmReset = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let client = model.clients.first(where: { $0.email == email }) {
                List {
                    statusSection(client)
                    trafficSection(client)
                    detailsSection(client)
                    Section {
                        Button { showShare = true } label: { Label("Share links and QR", systemImage: "qrcode") }
                        Button { confirmReset = true } label: { Label("Reset traffic", systemImage: "arrow.counterclockwise") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete client", systemImage: "trash") }
                    }
                    if let loadError {
                        Section { StateNotice(symbol: "exclamationmark.triangle", text: loadError, tint: .red) }
                    }
                }
                .navigationTitle(client.email)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { showEdit = true }.disabled(detail == nil)
                    }
                }
                .sheet(isPresented: $showEdit, onDismiss: { Task { await reloadAfterEdit() } }) { ClientEditorView(editing: detail) }
                .sheet(isPresented: $showShare) { ShareClientSheet(client: client) }
                .confirmationDialog("Reset the traffic of \(client.email)?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset traffic", role: .destructive) { Task { await model.resetTraffic(of: client) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The used traffic goes back to zero. This cannot be undone.")
                }
                .confirmationDialog("Delete \(client.email)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete client", role: .destructive) {
                        Task {
                            await model.delete(client)
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The client loses access on every inbound. This cannot be undone.")
                }
            } else {
                ContentUnavailableView("Client not found", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        // Reload when anything about the client changes in the list (toggle, edit, reset), not only the switch.
        .task(id: model.clients.first(where: { $0.email == email })) { await load() }
    }

    /// After the editor closes: reload the record. A rename leaves nothing under this email, so go back to the list.
    private func reloadAfterEdit() async {
        await load()
        if model.clientsState == .loaded, !model.clients.contains(where: { $0.email == email }) { dismiss() }
    }

    private func load() async {
        do {
            detail = try await model.clientDetail(email: email)
            loadError = nil
        } catch {
            loadError = "Could not load the full client record. " + error.panelMessage
        }
    }

    private func statusSection(_ client: VPNClient) -> some View {
        Section {
            Toggle("Enabled", isOn: Binding(
                get: { client.enable },
                set: { value in Task { await model.setClient(client, enabled: value) } }
            ))
            .disabled(model.busyClients.contains(client.email))
            LabeledContent("Online") {
                if model.isOnline(client) {
                    Label("Now", systemImage: "circle.fill").foregroundStyle(.green)
                } else {
                    Text(lastOnlineText(client)?.replacingOccurrences(of: "Last online ", with: "") ?? "Never")
                }
            }
        }
    }

    private func trafficSection(_ client: VPNClient) -> some View {
        Section("Traffic") {
            TrafficMeter(used: client.usedBytes, limit: client.limitBytes)
            LabeledContent("Upload", value: Format.bytes(client.traffic?.up ?? 0))
            LabeledContent("Download", value: Format.bytes(client.traffic?.down ?? 0))
        }
    }

    private func detailsSection(_ client: VPNClient) -> some View {
        let expiry = ExpiryInfo.describe(expiryTime: client.expiryTime)
        return Section("Details") {
            LabeledContent("Expires") {
                Text(expiry.text).foregroundStyle(expiry.isUrgent ? Color.red : Color.secondary)
            }
            LabeledContent("IP limit", value: client.limitIp == 0 ? "No limit" : String(client.limitIp))
            if !client.comment.isEmpty { LabeledContent("Note", value: client.comment) }
            if !client.subId.isEmpty { LabeledContent("Subscription id", value: client.subId) }
            let names = client.inboundIds.compactMap { id in model.inbounds.first { $0.id == id }.map { $0.remark.isEmpty ? "Inbound \($0.id)" : $0.remark } }
            if !names.isEmpty { LabeledContent("Inbounds", value: names.joined(separator: ", ")) }
        }
    }
}

/// Adds or edits a client.
struct ClientEditorView: View {
    private enum ExpiryChoice: Hashable { case never, date, afterFirstUse }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: ClientDetail?

    @State private var draft = ClientDraft()
    @State private var limitText = ""
    @State private var choice: ExpiryChoice = .never
    @State private var date = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var days = 30
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.email)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("Enabled", isOn: $draft.enable)
                    TextField("Note (optional)", text: $draft.comment)
                } footer: {
                    Text("The name has no spaces or slashes. It is how the panel and the alerts call this client.")
                }
                Section {
                    HStack {
                        TextField("0 means unlimited", text: $limitText).keyboardType(.decimalPad)
                        Text("GB").foregroundStyle(.secondary)
                    }
                    Stepper(value: $draft.limitIp, in: 0...1000) {
                        LabeledContent("Devices at once", value: draft.limitIp == 0 ? "No limit" : String(draft.limitIp))
                    }
                } header: {
                    Text("Limits")
                }
                Section("Expiry") {
                    Picker("Expires", selection: $choice) {
                        Text("Never").tag(ExpiryChoice.never)
                        Text("On a date").tag(ExpiryChoice.date)
                        Text("After first use").tag(ExpiryChoice.afterFirstUse)
                    }
                    if choice == .date {
                        DatePicker("Date", selection: $date, in: Date()..., displayedComponents: .date)
                    }
                    if choice == .afterFirstUse {
                        Stepper(value: $days, in: 1...36500) {
                            LabeledContent("Days", value: String(days))
                        }
                    }
                }
                Section {
                    TextField("Leave empty to let the panel choose", text: $draft.subId)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Make a random id") { draft.subId = ClientDraft.randomSubId() }
                } header: {
                    Text("Subscription id")
                }
                if draft.isNew {
                    Section {
                        if model.inbounds.isEmpty {
                            Text("Add an inbound first.").foregroundStyle(.secondary)
                        }
                        ForEach(model.inbounds) { inbound in
                            Button {
                                toggle(inbound)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(inbound.remark.isEmpty ? "Inbound \(inbound.id)" : inbound.remark).foregroundStyle(.primary)
                                        Text("\(inbound.summary), port \(inbound.port)").font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if draft.inboundIds.contains(inbound.id) {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                            .accessibilityAddTraits(draft.inboundIds.contains(inbound.id) ? .isSelected : [])
                        }
                    } header: {
                        Text("Inbounds")
                    } footer: {
                        Text("The client can connect through every inbound you tick.")
                    }
                }
                if let errorText {
                    Section { StateNotice(symbol: "exclamationmark.triangle", text: errorText, tint: .red) }
                }
                if let problem = currentDraft().validationError {
                    Section { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(draft.isNew ? "New client" : "Edit client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() } else {
                        Button("Save") { Task { await save() } }
                            .disabled(currentDraft().validationError != nil)
                    }
                }
            }
            .onAppear(perform: load)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let editing {
            draft = ClientDraft(editing: editing)
            limitText = draft.totalGB == 0 ? "" : trimmed(draft.totalGB)
            switch draft.expiry ?? .never {
            case .never: choice = .never
            case .date(let value): choice = .date; date = value
            case .afterFirstUse(let value): choice = .afterFirstUse; days = value
            }
        } else if let first = model.inbounds.first(where: { $0.enable }) ?? model.inbounds.first {
            toggle(first)
        }
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func toggle(_ inbound: Inbound) {
        if let index = draft.inboundIds.firstIndex(of: inbound.id) {
            draft.inboundIds.remove(at: index)
        } else {
            draft.inboundIds.append(inbound.id)
        }
        let anyReality = model.inbounds.contains { draft.inboundIds.contains($0.id) && $0.reality != nil }
        draft.flow = anyReality ? ClientDraft.visionFlow : ""
    }

    /// The draft with the form's raw inputs applied.
    private func currentDraft() -> ClientDraft {
        var copy = draft
        let text = limitText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        copy.totalGB = text.isEmpty ? 0 : (Double(text) ?? -1)
        switch choice {
        case .never: copy.expiry = .never
        case .date: copy.expiry = .date(ClientExpiry.endOfDay(date))
        case .afterFirstUse: copy.expiry = .afterFirstUse(days: days)
        }
        return copy
    }

    private func save() async {
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            try await model.save(currentDraft())
            dismiss()
        } catch {
            errorText = error.panelMessage
        }
    }
}

/// The links of one client: the subscription and one share link per inbound, each as text, QR code,
/// copy button and the iOS share sheet.
struct ShareClientSheet: View {
    private struct Item: Identifiable, Hashable {
        let id: String
        let title: String
        let value: String
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let client: VPNClient
    @State private var links: [String] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selection: String?
    @State private var copied: String?

    private var items: [Item] {
        var result: [Item] = []
        if let sub = model.subscriptionLink(for: client) {
            result.append(Item(id: "sub", title: "Subscription", value: sub))
        }
        for (index, link) in links.enumerated() {
            result.append(Item(id: "link-\(index)", title: linkTitle(link, index: index), value: link))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    let items = items
                    if items.count > 1 {
                        Picker("Link", selection: Binding(get: { selection ?? items.first?.id ?? "" }, set: { selection = $0 })) {
                            ForEach(items) { Text($0.title).tag($0.id) }
                        }
                        .pickerStyle(.menu)
                    }
                    if let item = items.first(where: { $0.id == selection }) ?? items.first {
                        card(item)
                    } else if isLoading {
                        ProgressView()
                    } else if errorText == nil {
                        StateNotice(
                            symbol: "link.badge.plus",
                            text: client.subId.isEmpty
                                ? "This client has no subscription id and no share link."
                                : "Set the subscription base URL in Settings to share a subscription link."
                        )
                    }
                    if let errorText {
                        StateNotice(symbol: "exclamationmark.triangle", text: errorText, tint: .red)
                    }
                }
                .padding()
            }
            .navigationTitle(client.email)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                do {
                    links = try await model.shareLinks(email: client.email)
                } catch {
                    errorText = "Could not load the share links. " + error.panelMessage
                }
                isLoading = false
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func card(_ item: Item) -> some View {
        VStack(spacing: 16) {
            if let image = QRCode.cgImage(for: item.value) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("QR code of the \(item.title) link")
            }
            Text(item.value)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                ShareLink(item: item.value) {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    UIPasteboard.general.string = item.value
                    copied = item.id
                } label: {
                    Label(copied == item.id ? "Copied" : "Copy", systemImage: copied == item.id ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    /// `vless://...#Name` becomes `VLESS Name`; anything else is `Link 2`.
    private func linkTitle(_ link: String, index: Int) -> String {
        let scheme = link.prefix(while: { $0 != ":" }).uppercased()
        if let hash = link.lastIndex(of: "#") {
            let name = String(link[link.index(after: hash)...]).removingPercentEncoding ?? ""
            if !name.isEmpty { return "\(scheme) \(name)" }
        }
        return "\(scheme.isEmpty ? "Link" : scheme) \(index + 1)"
    }
}
