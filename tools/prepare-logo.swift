// SPDX-License-Identifier: GPL-3.0-or-later
// Renders a vendor's SVG logo to a trimmed, square, transparent 256x256 PNG for Resources/OSLogos.
// Usage: swift tools/prepare-logo.swift in.svg out.png [--first-glyph]
//   --first-glyph keeps only the leftmost shape (used for Fedora, whose official file is symbol + wordmark).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]) else { print("cannot load \(args.dropFirst())"); exit(1) }
let firstGlyph = args.contains("--first-glyph")

let big = 2048
let k = CGFloat(big) / max(source.size.width, source.size.height)
let w = Int(source.size.width * k), h = Int(source.size.height * k)
func bitmap(_ w: Int, _ h: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}
let rep = bitmap(w, h)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
source.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.restoreGraphicsState()

func alpha(_ x: Int, _ y: Int) -> UInt8 { rep.bitmapData![y * rep.bytesPerRow + x * 4 + 3] }
var columns = (0..<w).map { x in (0..<h).contains { alpha(x, $0) > 8 } }
var minX = columns.firstIndex(of: true) ?? 0, maxX = columns.lastIndex(of: true) ?? w - 1
if firstGlyph {
    // The first run of occupied columns, ignoring gaps narrower than 1% of the width.
    var x = minX, gap = 0
    while x < w, gap < w / 100 { if columns[x] { gap = 0; maxX = x } else { gap += 1 }; x += 1 }
}
columns = []
let rows = (0..<h).map { y in (minX...maxX).contains { alpha($0, y) > 8 } }
let minY = rows.firstIndex(of: true) ?? 0, maxY = rows.lastIndex(of: true) ?? h - 1
let cw = maxX - minX + 1, ch = maxY - minY + 1, side = max(cw, ch)

let out = bitmap(256, 256)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high
let scale = 256 / CGFloat(side)
let destination = NSRect(x: (256 - CGFloat(cw) * scale) / 2, y: (256 - CGFloat(ch) * scale) / 2,
                         width: CGFloat(cw) * scale, height: CGFloat(ch) * scale)
// NSBitmapImageRep rows run top-down; drawing coordinates run bottom-up.
let cropped = NSImage(size: NSSize(width: w, height: h)); cropped.addRepresentation(rep)
cropped.draw(in: destination, from: NSRect(x: minX, y: h - 1 - maxY, width: cw, height: ch), operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) from \(cw)x\(ch)")
