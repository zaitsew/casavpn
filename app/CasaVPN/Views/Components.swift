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

/// Where the project's docs live. The app links to them from the sign-in screen and the error notices.
enum DocsLink {
    static let quickstart = URL(string: "https://github.com/zaitsew/casavpn/blob/main/docs/QUICKSTART.md")!
    static let remoteAccess = URL(string: "https://github.com/zaitsew/casavpn/blob/main/docs/APP.md#reaching-the-panel-from-outside")!
}

/// The notice for a failed panel source.
struct PanelStateNotice: View {
    @Environment(AppModel.self) private var model
    let state: LoadState

    var body: some View {
        switch state {
        case .unreachable:
            StateNotice(symbol: "wifi.slash", text: PanelMessages.unreachable, tint: .orange)
            Link("How to reach the panel", destination: DocsLink.remoteAccess).font(.footnote)
        case .tls:
            StateNotice(symbol: "lock.trianglebadge.exclamationmark", text: PanelMessages.tls, tint: .red)
        case .refused:
            StateNotice(symbol: "hand.raised.slash", text: PanelMessages.refused, tint: .orange)
            Link("Reaching the panel from outside", destination: DocsLink.remoteAccess).font(.footnote)
        case .unauthorized:
            StateNotice(symbol: "key.slash", text: PanelMessages.unauthorized, tint: .red)
            Button("Sign in again") { model.showReauth = true }
        case .forbidden:
            StateNotice(symbol: "lock", text: PanelMessages.forbidden(""), tint: .orange)
        case .failed(let message):
            StateNotice(symbol: "exclamationmark.triangle", text: message, tint: .red)
        case .notConfigured:
            StateNotice(symbol: "gearshape", text: "Sign in to your panel in Settings.")
        case .idle, .loading, .loaded:
            EmptyView()
        }
    }
}

struct RelayStateNotice: View {
    let state: LoadState

    var body: some View {
        switch state {
        case .unreachable, .tls, .refused:
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

/// A used-of-limit bar with the text above it, as the panel shows traffic.
struct TrafficMeter: View {
    let used: Int64
    let limit: Int64?

    var body: some View {
        let fraction = Format.trafficFraction(used: used, limit: limit)
        VStack(alignment: .leading, spacing: 4) {
            Text(Format.traffic(used: used, limit: limit)).font(.subheadline).foregroundStyle(.secondary)
            if let fraction {
                ProgressView(value: fraction)
                    .tint(fraction >= 1 ? .red : fraction >= 0.9 ? .orange : .accentColor)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small coloured capsule: `VLESS`, `Reality`, `Off`.
struct Tag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// The text of a thrown error, for an alert.
extension Error {
    var panelMessage: String { (self as? LocalizedError)?.errorDescription ?? localizedDescription }
}
