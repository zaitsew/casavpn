import CasaKit
import SwiftUI

/// The newest lines of Xray's access log or of the panel's own log, with a filter.
struct XrayLogView: View {
    private enum Source: String, CaseIterable, Identifiable {
        case access = "Access"
        case panel = "Panel"
        var id: String { rawValue }
    }

    private struct Line: Identifiable {
        let id = UUID()
        let text: String
        let isBlocked: Bool
    }

    @Environment(AppModel.self) private var model
    @State private var source: Source = .access
    @State private var count = 200
    @State private var filter = ""
    @State private var lines: [Line] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Picker("Log", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let errorText {
                Section { StateNotice(symbol: "exclamationmark.triangle", text: errorText, tint: .red) }
            }
            if isLoading && lines.isEmpty {
                Section { ProgressView() }
            } else if loaded && lines.isEmpty && errorText == nil {
                Section {
                    StateNotice(
                        symbol: "text.alignleft",
                        text: filter.isBlank ? "The log is empty." : "No line contains \"\(filter)\"."
                    )
                }
            }
            if !lines.isEmpty {
                Section {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.isBlocked ? Color.red : Color.primary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("The newest \(lines.count) lines, oldest first.")
                }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter")
        .onSubmit(of: .search) { Task { await load() } }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Lines", selection: $count) {
                        ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0) lines").tag($0) }
                    }
                } label: {
                    Label("Lines", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .task { await load() }
        .onChange(of: source) { _, _ in Task { await load() } }
        .onChange(of: count) { _, _ in Task { await load() } }
    }

    private func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false; loaded = true }
        do {
            switch source {
            case .access:
                let entries = try await model.xrayLog(count: count, filter: filter)
                lines = entries.map { Line(text: $0.line, isBlocked: $0.event == .blocked) }
            case .panel:
                let texts = try await model.panelLog(count: count, level: "info")
                let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                lines = texts.filter { needle.isEmpty || $0.lowercased().contains(needle) }.map { Line(text: $0, isBlocked: false) }
            }
        } catch {
            lines = []
            errorText = error.panelMessage
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
