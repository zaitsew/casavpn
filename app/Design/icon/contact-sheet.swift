// Builds contact-sheet.png: every concept at 1024, 180 and 60 px, masked like iOS, on a light and a dark background.
// Usage: swiftc -O contact-sheet.swift -o /tmp/icon-sheet && /tmp/icon-sheet out.png a.png b.png c.png
import Cocoa

let args = Array(CommandLine.arguments.dropFirst())
let out = args[0]
let files = Array(args.dropFirst())
func load(_ p: String) -> CGImage {
    let d = NSData(contentsOfFile: p)!
    return NSBitmapImageRep(data: d as Data)!.cgImage!
}
let imgs = files.map(load)
let cellW = 1160, cellH = 1360
let W = cellW * imgs.count, H = cellH * 2
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high

func icon(_ img: CGImage, x: Int, y: Int, size: Int) {
    let r = CGRect(x: x, y: y, width: size, height: size)
    ctx.saveGState()
    let rad = CGFloat(size) * 0.2237
    // soft shadow
    ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(size) * 0.02), blur: CGFloat(size) * 0.05,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
    ctx.clip()
    ctx.draw(img, in: r)
    ctx.restoreGState()
}

for row in 0..<2 {
    let light = row == 0
    // CoreGraphics origin is bottom-left; row 0 (light) goes on top.
    let baseY = light ? cellH : 0
    ctx.setFillColor(light ? CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)
                           : CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
    ctx.fill(CGRect(x: 0, y: baseY, width: W, height: cellH))
    for (i, img) in imgs.enumerated() {
        let x0 = i * cellW
        icon(img, x: x0 + 68, y: baseY + 268, size: 1024)
        icon(img, x: x0 + 68, y: baseY + 48, size: 180)
        icon(img, x: x0 + 68 + 180 + 60, y: baseY + 48 + 60, size: 120)
        icon(img, x: x0 + 68 + 180 + 60 + 120 + 60, y: baseY + 48 + 90, size: 60)
        icon(img, x: x0 + 68 + 180 + 60 + 120 + 60 + 60 + 40, y: baseY + 48 + 110, size: 40)
    }
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
