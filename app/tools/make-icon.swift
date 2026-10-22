#!/usr/bin/env swift
// Draws the 1024x1024 app icon: a house inside a shield, on a solid blue.
//   swift app/tools/make-icon.swift app/CasaVPN/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

// Opaque, no alpha: the App Store refuses icons with transparency.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.noneSkipLast.rawValue
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else {
    fatalError("no context")
}

let blue = CGColor(srgbRed: 0.09, green: 0.42, blue: 0.69, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

ctx.setFillColor(blue)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Shield, centered. Coordinates are y-up.
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 880))
shield.addLine(to: CGPoint(x: 800, y: 790))
shield.addLine(to: CGPoint(x: 800, y: 540))
shield.addCurve(to: CGPoint(x: 512, y: 140), control1: CGPoint(x: 800, y: 340), control2: CGPoint(x: 660, y: 220))
shield.addCurve(to: CGPoint(x: 224, y: 540), control1: CGPoint(x: 364, y: 220), control2: CGPoint(x: 224, y: 340))
shield.addLine(to: CGPoint(x: 224, y: 790))
shield.closeSubpath()
ctx.setFillColor(white)
ctx.addPath(shield)
ctx.fillPath()

// House cut out of the shield, in the background blue.
let house = CGMutablePath()
house.move(to: CGPoint(x: 512, y: 680))      // roof peak
house.addLine(to: CGPoint(x: 676, y: 540))
house.addLine(to: CGPoint(x: 640, y: 540))
house.addLine(to: CGPoint(x: 640, y: 360))   // right wall down
house.addLine(to: CGPoint(x: 560, y: 360))
house.addLine(to: CGPoint(x: 560, y: 470))   // door
house.addLine(to: CGPoint(x: 464, y: 470))
house.addLine(to: CGPoint(x: 464, y: 360))
house.addLine(to: CGPoint(x: 384, y: 360))
house.addLine(to: CGPoint(x: 384, y: 540))
house.addLine(to: CGPoint(x: 348, y: 540))
house.closeSubpath()
ctx.setFillColor(blue)
ctx.addPath(house)
ctx.fillPath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot write \(output)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot finalize \(output)") }
print("wrote \(output)")
