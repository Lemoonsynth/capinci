// Fits artwork onto Apple's macOS icon grid: a 824 pt continuous-corner squircle
// centred on a 1024 canvas, transparent outside. macOS 26 shows icons of any other
// shape inside a white plate in the Dock.
// Usage: make-icon <artwork.png> <out.png> [cropX cropY cropSize]

import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count >= 3, let art = NSImage(contentsOfFile: args[1]),
      let cg = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: make-icon <artwork.png> <out.png> [cropX cropY cropSize]")
    exit(2)
}

// Optional crop of the artwork (pixels), default: the whole image.
var crop = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
if args.count == 6, let x = Double(args[3]), let y = Double(args[4]), let s = Double(args[5]) {
    crop = CGRect(x: x, y: y, width: s, height: s)
}
let source = cg.cropping(to: crop)!

let size = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let squircle = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tile).cgPath
ctx.addPath(squircle)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(source, in: tile)

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
