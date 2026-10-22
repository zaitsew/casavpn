// Renders SVG files to opaque 1024x1024 PNGs (no alpha channel) with WebKit.
// Usage: swiftc -O render.swift -o /tmp/icon-render && /tmp/icon-render in.svg out.png [in2.svg out2.png ...]
import Cocoa
import WebKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, args.count % 2 == 0 else {
    FileHandle.standardError.write("usage: render in.svg out.png [...]\n".data(using: .utf8)!)
    exit(2)
}
let jobs = stride(from: 0, to: args.count, by: 2).map { (args[$0], args[$0 + 1]) }
let size = 1024

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var index = 0
    override init() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = web
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
    }
    func next() {
        if index >= jobs.count { exit(0) }
        let svg = try! String(contentsOfFile: jobs[index].0, encoding: .utf8)
        let html = "<!doctype html><html><head><style>html,body{margin:0;padding:0;background:#000;overflow:hidden}svg{display:block;width:\(size)px;height:\(size)px}</style></head><body>\(svg)</body></html>"
        web.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let c = WKSnapshotConfiguration()
            c.rect = CGRect(x: 0, y: 0, width: size, height: size)
            c.snapshotWidth = NSNumber(value: size)
            webView.takeSnapshot(with: c) { image, err in
                guard let image = image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    FileHandle.standardError.write("snapshot failed: \(String(describing: err))\n".data(using: .utf8)!)
                    exit(1)
                }
                // Flatten onto an opaque context: PNG without alpha.
                let cs = CGColorSpace(name: CGColorSpace.sRGB)!
                let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
                let out = ctx.makeImage()!
                let rep = NSBitmapImageRep(cgImage: out)
                let data = rep.representation(using: .png, properties: [:])!
                try! data.write(to: URL(fileURLWithPath: jobs[self.index].1))
                print("wrote \(jobs[self.index].1)")
                self.index += 1
                self.next()
            }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let r = Renderer()
r.window.orderBack(nil)
DispatchQueue.main.async { r.next() }
app.run()
