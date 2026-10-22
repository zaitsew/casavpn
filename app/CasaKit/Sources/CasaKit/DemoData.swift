import Foundation

/// The sample content of the demo panel. Everything is fictional: hosts are `example.com`,
/// addresses are in `203.0.113.0/24`, client names are generic.
enum DemoData {
    struct Seed {
        var status: ServerStatus
        var inbounds: [Inbound]
        var clients: [DemoPanel.DemoClient]
        var online: Set<String>
    }

    private static let gigabyte: Int64 = 1_073_741_824
    private static let day: Double = 86_400

    static func make(now: Date) -> Seed {
        let status = ServerStatus(
            cpu: 14, cpuCores: 4,
            mem: .init(current: 1_610_612_736, total: 4_294_967_296),
            swap: .init(current: 134_217_728, total: 2_147_483_648),
            disk: .init(current: 9_663_676_416, total: 42_949_672_960),
            xray: .init(state: .running, errorMsg: "", version: "26.7.28"),
            uptime: 2_937_600, loads: [0.21, 0.34, 0.29], tcpCount: 64, udpCount: 12,
            netUp: 184_320, netDown: 1_126_400, netSent: 412 * UInt64(gigabyte), netReceived: 655 * UInt64(gigabyte),
            panelVersion: "3.10.2", publicIPv4: "203.0.113.10"
        )

        func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
        func ago(_ seconds: Double) -> Int64 { ms(now.addingTimeInterval(-seconds)) }
        func ahead(_ days: Double) -> Int64 { ms(now.addingTimeInterval(days * day)) }

        func client(
            _ email: String, id: Int, limitGB: Int64 = 0, expiry: Int64 = 0, enable: Bool = true,
            inbounds: [Int], flow: String = "xtls-rprx-vision", comment: String = "", limitIp: Int = 0,
            used: Double, lastOnline: Int64
        ) -> DemoPanel.DemoClient {
            let bytes = Int64(used * Double(gigabyte))
            return DemoPanel.DemoClient(
                detail: ClientDetail(
                    email: email, uuid: String(format: "00000000-0000-4000-8000-%012d", id),
                    subId: "demo\(String(format: "%012d", id))", enable: enable, totalBytes: limitGB * gigabyte,
                    expiryTime: expiry, limitIp: limitIp, comment: comment, flow: flow, inboundIds: inbounds,
                    usedBytes: bytes
                ),
                up: bytes / 6, down: bytes - bytes / 6, lastOnline: lastOnline
            )
        }

        let clients = [
            client("Laptop", id: 1, inbounds: [1], comment: "Home laptop", used: 38.4, lastOnline: ago(40)),
            client("Phone", id: 2, limitGB: 200, expiry: ahead(41), inbounds: [1], comment: "Main phone", limitIp: 3, used: 71.2, lastOnline: ago(15)),
            client("Tablet", id: 3, limitGB: 100, expiry: ahead(120), inbounds: [1], used: 12.8, lastOnline: ago(5 * 3600)),
            client("Guest", id: 4, limitGB: 10, expiry: ahead(3), inbounds: [1, 2], comment: "Visitors", limitIp: 2, used: 9.6, lastOnline: ago(2 * 3600)),
            client("TV", id: 5, inbounds: [2], flow: "", comment: "Living room", used: 54.1, lastOnline: ago(26 * 3600)),
            client("Work-Laptop", id: 6, limitGB: 500, expiry: ahead(-12), enable: false, inbounds: [1], used: 187.3, lastOnline: ago(12 * day)),
        ]

        let reality = RealityInboundDraft(
            inboundId: 1, remark: "Home Reality", port: 443, target: "www.example.com:443",
            serverNamesText: "www.example.com", shortIdsText: "a1b2c3d4, e5f60718",
            privateKey: DemoPanel.realityPrivateKey, publicKey: DemoPanel.realityPublicKey
        )
        let realityInbound: Inbound = {
            let body = (try? reality.makeBody(existing: nil)) ?? Data()
            var inbound = (try? inbound(fromBody: body, id: 1)) ?? Inbound(id: 1, remark: "Home Reality", port: 443)
            inbound.tag = "inbound-443"
            return inbound
        }()

        let shadowsocks = Inbound(
            id: 2, remark: "Backup Shadowsocks", enable: true, port: 8388, protocolName: "shadowsocks",
            tag: "inbound-8388",
            settings: JSONDocument.string([
                "method": "chacha20-ietf-poly1305", "network": "tcp,udp", "clients": [Any](),
            ]),
            streamSettings: JSONDocument.string([
                "network": "tcp", "security": "none", "tcpSettings": ["header": ["type": "none"]],
            ])
        )

        return Seed(
            status: status, inbounds: [realityInbound, shadowsocks], clients: clients,
            online: ["Laptop", "Phone"]
        )
    }

    /// An `Inbound` from the JSON body `RealityInboundDraft.makeBody` builds, given the id the panel would assign.
    static func inbound(fromBody body: Data, id: Int) throws -> Inbound {
        guard var root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { throw PanelError.decoding }
        root["id"] = id
        if (root["tag"] as? String)?.isEmpty ?? true, let port = root["port"] as? Int { root["tag"] = "inbound-\(port)" }
        let data = try JSONSerialization.data(withJSONObject: root)
        guard let inbound = try? JSONDecoder().decode(Inbound.self, from: data) else { throw PanelError.decoding }
        return inbound
    }

    /// What `GET /inbounds/get/:id` would send for the inbound.
    static func rawJSON(of inbound: Inbound) -> Data {
        var root: [String: Any] = [
            "id": inbound.id, "remark": inbound.remark, "enable": inbound.enable, "port": inbound.port,
            "protocol": inbound.protocolName, "listen": inbound.listen, "tag": inbound.tag,
            "up": inbound.up, "down": inbound.down, "total": inbound.total, "expiryTime": inbound.expiryTime,
            "disableFlow": inbound.disableFlow,
            "settings": inbound.settings, "streamSettings": inbound.streamSettings,
        ]
        root["sniffing"] = JSONDocument.string([
            "enabled": true, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": false, "routeOnly": false,
        ])
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    /// The share link the panel would build for a client of the inbound.
    static func link(for client: ClientDetail, in inbound: Inbound) -> String {
        let name = encode("\(inbound.remark)-\(client.email)")
        if inbound.protocolName == "shadowsocks" {
            let credentials = Data("chacha20-ietf-poly1305:demo-\(client.subId)".utf8).base64EncodedString()
            return "ss://\(credentials)@\(DemoPanel.host):\(inbound.port)#\(name)"
        }
        let reality = inbound.reality
        var query = ["type=tcp", "encryption=none", "security=reality"]
        query.append("pbk=\(reality?.publicKey ?? DemoPanel.realityPublicKey)")
        query.append("fp=\(reality?.fingerprint ?? "chrome")")
        query.append("sni=\(reality?.serverNames.first ?? "www.example.com")")
        query.append("sid=\(reality?.shortIds.first ?? "a1b2c3d4")")
        query.append("spx=%2F")
        if !client.flow.isEmpty { query.append("flow=\(client.flow)") }
        return "vless://\(client.uuid)@\(DemoPanel.host):\(inbound.port)?\(query.joined(separator: "&"))#\(name)"
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func accessLog(now: Date, emails: [String]) -> [XrayLogEntry] {
        let sites = ["api.example.com:443", "cdn.example.org:443", "mail.example.net:993", "video.example.com:443", "chat.example.org:443"]
        let sources = ["203.0.113.21", "203.0.113.34", "203.0.113.55", "203.0.113.89"]
        let people = emails.isEmpty ? ["Laptop"] : emails
        return (0..<60).map { index in
            XrayLogEntry(
                date: now.addingTimeInterval(-Double(60 - index) * 45),
                from: "\(sources[index % sources.count]):\(40_000 + index * 37)",
                to: sites[(index * 3) % sites.count],
                inbound: "inbound-443",
                outbound: index % 17 == 0 ? "blocked" : "direct",
                email: people[index % people.count],
                event: index % 17 == 0 ? .blocked : .proxied
            )
        }
    }

    static func panelLog(now: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let messages = [
            "INFO - Web server running HTTPS on [::]:8443",
            "INFO - Xray 26.7.28 started",
            "INFO - Subscription server listening on [::]:2096",
            "INFO - logged in successfully: username=\"admin\", IP=\"203.0.113.77\"",
            "INFO - Traffic statistics saved",
            "WARNING - Client Guest is close to its traffic limit",
        ]
        return messages.enumerated().map { index, message in
            "\(formatter.string(from: now.addingTimeInterval(-Double(messages.count - index) * 600))) \(message)"
        }
    }
}
