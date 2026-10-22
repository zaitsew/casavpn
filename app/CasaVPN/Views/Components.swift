import CasaKit
import SwiftUI

extension Severity {
    var symbol: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    var label: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        }
    }
}

/// A line of text that says what is wrong and, when useful, where to go next.
struct StateNotice: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The notice for a failed panel source. `forbiddenText` differs per tab.
struct PanelStateNotice: View {
    let state: LoadState
    var forbiddenText: String = PanelMessages.cannotListClients

    var body: some View {
        switch state {
        case .unreachable:
            StateNotice(symbol: "wifi.slash", text: PanelMessages.unreachable, tint: .orange)
        case .unauthorized:
            StateNotice(symbol: "key.slash", text: "The panel rejected the API token. Check it in Settings.", tint: .red)
        case .forbidden:
            StateNotice(symbol: "lock", text: forbiddenText, tint: .orange)
        case .failed(let message):
            StateNotice(symbol: "exclamationmark.triangle", text: message, tint: .red)
        case .notConfigured:
            StateNotice(symbol: "gearshape", text: "Add the panel URL and token in Settings.")
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }
}

struct RelayStateNotice: View {
    let state: LoadState

    var body: some View {
        switch state {
        case .unreachable:
            StateNotice(symbol: "wifi.slash", text: "The relay did not answer. Check the connection and the relay URL.", tint: .orange)
        case .unauthorized:
            StateNotice(symbol: "key.slash", text: "The relay rejected the app token. Check it in Settings.", tint: .red)
        case .failed(let message):
            StateNotice(symbol: "exclamationmark.triangle", text: message, tint: .red)
        case .forbidden:
            StateNotice(symbol: "lock", text: "The relay refused the request.", tint: .red)
        case .notConfigured:
            StateNotice(symbol: "gearshape", text: "Add the relay URL and token in Settings.")
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }
}

extension Date {
    /// `3 minutes ago`
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
