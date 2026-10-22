import CasaKit
import Foundation

/// Sample alerts for the demo: the kinds the relay sends, with fictional content.
enum DemoAlerts {
    static func sample(now: Date) -> [VPNAlert] {
        func alert(_ id: String, _ kind: String, _ severity: Severity, _ title: String, _ body: String, minutesAgo: Double) -> VPNAlert {
            VPNAlert(id: id, kind: kind, severity: severity, title: title, body: body, at: now.addingTimeInterval(-minutesAgo * 60), source: "demo")
        }
        return [
            alert("demo-1", "client.traffic", .warning, "Guest used 96% of its traffic", "Guest has used 9.6 GB of 10 GB.", minutesAgo: 35),
            alert("demo-2", "client.expiring", .warning, "Guest expires in 3 days", "The client Guest stops working in 3 days.", minutesAgo: 190),
            alert("demo-3", "host.disk", .info, "Disk is 22% used", "The server disk has 31 GB free.", minutesAgo: 60 * 30),
            alert("demo-4", "vpn.up", .info, "The VPN is up again", "The port answered after 4 minutes.", minutesAgo: 60 * 52),
            alert("demo-5", "vpn.down", .critical, "The VPN is down", "The VPN port did not answer for 3 checks.", minutesAgo: 60 * 52 + 4),
        ]
    }

    static func monitor(now: Date) -> Monitor {
        Monitor(status: .up, since: now.addingTimeInterval(-52 * 3600), lastCheck: now.addingTimeInterval(-90), ip: "203.0.113.10", target: "demo.example.com:443")
    }
}
