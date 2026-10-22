import CasaKit
import SwiftUI

struct InboundsView: View {
    @Environment(AppModel.self) private var model
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                if model.inboundsState.isFailure || model.inboundsState == .notConfigured {
                    Section { PanelStateNotice(state: model.inboundsState) }
                }
                if model.inboundsState == .loading && model.inbounds.isEmpty {
                    Section { ProgressView() }
                }
                if model.inboundsState == .loaded && model.inbounds.isEmpty {
                    Section {
                        StateNotice(symbol: "point.3.connected.trianglepath.dotted", text: "The panel has no inbounds yet. Tap + to add a VLESS Reality inbound.")
                    }
                }
                if !model.inbounds.isEmpty {
                    Section {
                        ForEach(model.inbounds) { inbound in
                            NavigationLink(value: inbound.id) { InboundRow(inbound: inbound) }
                        }
                    } footer: {
                        Text("\(model.inbounds.count) inbounds, \(model.clients.isEmpty ? model.inbounds.reduce(0) { $0 + $1.clientCount } : model.clients.count) clients")
                    }
                }
            }
            .navigationTitle("Inbounds")
            .navigationDestination(for: Int.self) { InboundDetailView(inboundId: $0) }
            .refreshable { await model.refreshInbounds() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Label("Add inbound", systemImage: "plus") }
                        .disabled(!model.hasPanelAccess)
                }
            }
            .sheet(isPresented: $showNew) { InboundEditorView(editing: nil) }
        }
    }
}

private struct InboundRow: View {
    @Environment(AppModel.self) private var model
    let inbound: Inbound

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(inbound.remark.isEmpty ? "Inbound \(inbound.id)" : inbound.remark).font(.headline)
                    Tag(text: ":\(inbound.port)")
                }
                Text(inbound.summary).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(Format.bytes(inbound.up), systemImage: "arrow.up")
                    Label(Format.bytes(inbound.down), systemImage: "arrow.down")
                    Label("\(inbound.clientCount)", systemImage: "person.2")
                }
                .font(.footnote).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                if let limit = inbound.limitBytes {
                    TrafficMeter(used: inbound.usedBytes, limit: limit)
                }
            }
            Spacer(minLength: 8)
            Toggle("Enabled", isOn: Binding(
                get: { inbound.enable },
                set: { value in Task { await model.setInbound(inbound, enabled: value) } }
            ))
            .labelsHidden()
            .disabled(model.busyInbounds.contains(inbound.id))
        }
        .accessibilityElement(children: .combine)
    }
}

struct InboundDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let inboundId: Int
    @State private var showEdit = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var copied: String?

    var body: some View {
        Group {
            if let inbound = model.inbounds.first(where: { $0.id == inboundId }) {
                List {
                    overview(inbound)
                    trafficSection(inbound)
                    if let reality = inbound.reality { realitySection(reality) }
                    clientsSection(inbound)
                    actionsSection(inbound)
                }
                .navigationTitle(inbound.remark.isEmpty ? "Inbound \(inbound.id)" : inbound.remark)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { showEdit = true }.disabled(!inbound.isEditableReality)
                    }
                }
                .sheet(isPresented: $showEdit) { InboundEditorView(editing: inbound) }
                .confirmationDialog("Reset the traffic of \(inbound.remark)?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset traffic", role: .destructive) { Task { await model.resetTraffic(of: inbound) } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The upload and download counters go back to zero. This cannot be undone.")
                }
                .confirmationDialog("Delete \(inbound.remark)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete inbound", role: .destructive) {
                        Task {
                            await model.delete(inbound)
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Its \(inbound.clientCount) clients lose this connection and cannot use it any more. This cannot be undone.")
                }
            } else {
                ContentUnavailableView("Inbound not found", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private func overview(_ inbound: Inbound) -> some View {
        Section {
            Toggle("Enabled", isOn: Binding(
                get: { inbound.enable },
                set: { value in Task { await model.setInbound(inbound, enabled: value) } }
            ))
            .disabled(model.busyInbounds.contains(inbound.id))
            LabeledContent("Protocol", value: inbound.summary)
            LabeledContent("Port", value: String(inbound.port))
            if !inbound.listen.isEmpty { LabeledContent("Listen", value: inbound.listen) }
            if !inbound.tag.isEmpty { LabeledContent("Tag", value: inbound.tag) }
        }
    }

    private func trafficSection(_ inbound: Inbound) -> some View {
        Section("Traffic") {
            LabeledContent("Upload", value: Format.bytes(inbound.up))
            LabeledContent("Download", value: Format.bytes(inbound.down))
            TrafficMeter(used: inbound.usedBytes, limit: inbound.limitBytes)
        }
    }

    private func realitySection(_ reality: RealityConfig) -> some View {
        Section {
            LabeledContent("Target", value: reality.target)
            LabeledContent("Server names", value: reality.serverNames.joined(separator: ", "))
            LabeledContent("Short IDs", value: reality.shortIds.joined(separator: ", "))
            LabeledContent("Fingerprint", value: reality.fingerprint)
            if !reality.publicKey.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Public key").foregroundStyle(.secondary).font(.footnote)
                    Text(reality.publicKey).font(.footnote.monospaced()).textSelection(.enabled)
                }
                Button {
                    UIPasteboard.general.string = reality.publicKey
                    copied = reality.publicKey
                } label: {
                    Label(copied == reality.publicKey ? "Copied" : "Copy public key", systemImage: copied == reality.publicKey ? "checkmark" : "doc.on.doc")
                }
            }
        } header: {
            Text("Reality")
        }
    }

    private func clientsSection(_ inbound: Inbound) -> some View {
        Section {
            if inbound.clientStats.isEmpty {
                Text("No clients use this inbound.").foregroundStyle(.secondary)
            }
            ForEach(inbound.clientStats, id: \.email) { stats in
                HStack {
                    if model.onlineEmails.contains(stats.email) {
                        Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green).accessibilityLabel("Online now")
                    }
                    Text(stats.email)
                    Spacer()
                    Text(Format.bytes(stats.up + stats.down)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Clients (\(inbound.clientCount))")
        }
    }

    private func actionsSection(_ inbound: Inbound) -> some View {
        Section {
            Button { confirmReset = true } label: { Label("Reset traffic", systemImage: "arrow.counterclockwise") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete inbound", systemImage: "trash") }
        } footer: {
            if !inbound.isEditableReality {
                Text("The app edits VLESS Reality inbounds. Open the panel in a browser to edit other protocols.")
            }
        }
    }
}

/// Adds or edits a VLESS Reality inbound.
struct InboundEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: Inbound?

    @State private var draft = RealityInboundDraft.newDraft()
    @State private var isSaving = false
    @State private var isGenerating = false
    @State private var errorText: String?
    @State private var confirmNewKeys = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Inbound") {
                    TextField("Name", text: $draft.remark)
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .focused($focused)
                    Toggle("Use the Vision flow (xtls-rprx-vision)", isOn: $draft.useVisionFlow)
                }
                Section {
                    TextField("www.example.com:443", text: $draft.target)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Server names, separated by commas", text: $draft.serverNamesText, axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Short IDs, separated by commas", text: $draft.shortIdsText, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        var ids = draft.shortIds
                        ids.append(RealityInboundDraft.randomShortId())
                        draft.shortIdsText = ids.joined(separator: ", ")
                    } label: {
                        Label("Add a random short ID", systemImage: "dice")
                    }
                } header: {
                    Text("Reality")
                } footer: {
                    Text("The target is a real site that supports TLS 1.3 and HTTP/2. Server names are what clients send as SNI.")
                }
                Section {
                    if draft.publicKey.isBlank {
                        Text("A key pair is made on the panel when you save.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Public key").foregroundStyle(.secondary).font(.footnote)
                            Text(draft.publicKey).font(.footnote.monospaced()).textSelection(.enabled)
                        }
                    }
                    Button {
                        if draft.isNew || draft.privateKey.isBlank { Task { await generateKeys() } } else { confirmNewKeys = true }
                    } label: {
                        HStack {
                            Label(draft.publicKey.isBlank ? "Generate a key pair now" : "Generate a new key pair", systemImage: "key")
                            if isGenerating { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isGenerating)
                } header: {
                    Text("Keys (x25519)")
                } footer: {
                    Text("The private key stays on the panel. A new key pair breaks every client link until clients import the new one.")
                }
                if let errorText {
                    Section { StateNotice(symbol: "exclamationmark.triangle", text: errorText, tint: .red) }
                }
                if let problem = draft.validationError {
                    Section { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(draft.isNew ? "New inbound" : "Edit inbound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() } else {
                        Button("Save") { Task { await save() } }
                            .disabled(draft.validationError != nil)
                    }
                }
            }
            .confirmationDialog("Generate a new key pair?", isPresented: $confirmNewKeys, titleVisibility: .visible) {
                Button("Generate", role: .destructive) { Task { await generateKeys() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Existing client links stop working until clients import the new public key.")
            }
            .onAppear {
                if let editing { draft = RealityInboundDraft(editing: editing) }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func generateKeys() async {
        isGenerating = true
        errorText = nil
        defer { isGenerating = false }
        do {
            let pair = try await model.newRealityKeyPair()
            draft.privateKey = pair.privateKey
            draft.publicKey = pair.publicKey
        } catch {
            errorText = error.panelMessage
        }
    }

    private func save() async {
        focused = false
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            try await model.save(draft)
            dismiss()
        } catch {
            errorText = error.panelMessage
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
