// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 OpenVM contributors
// This file is part of OpenVM, free software under the GNU General Public License v3.0 or later (see LICENSE).

import AppKit
import CoreGraphics

// Makes the artwork a full-bleed opaque square: the shape (alpha > 0.6) is flattened to opaque,
// and the transparent rounded corners are filled by extending the nearest edge colour.
let input = CommandLine.arguments[1], output = CommandLine.arguments[2]
guard let image = NSImage(contentsOfFile: input), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("cannot read") }
let w = cg.width, h = cg.height
let space = CGColorSpaceCreateDeviceRGB()
var pixels = [UInt8](repeating: 0, count: w * h * 4)
pixels.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}
var known = [Bool](repeating: false, count: w * h)
for i in 0..<(w * h) {
    let a = Int(pixels[i * 4 + 3])
    if a > 153 {                                   // inside the shape: un-premultiply, make opaque
        for c in 0..<3 { pixels[i * 4 + c] = UInt8(min(255, Int(pixels[i * 4 + c]) * 255 / a)) }
        pixels[i * 4 + 3] = 255
        known[i] = true
    }
}
var queue = [Int](); queue.reserveCapacity(w * h)
for i in 0..<(w * h) where known[i] {
    let x = i % w, y = i / w
    if (x > 0 && !known[i - 1]) || (x < w - 1 && !known[i + 1]) || (y > 0 && !known[i - w]) || (y < h - 1 && !known[i + w]) { queue.append(i) }
}
var head = 0
while head < queue.count {
    let i = queue[head]; head += 1
    let x = i % w, y = i / w
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
        let j = ny * w + nx
        if !known[j] {
            known[j] = true
            for c in 0..<3 { pixels[j * 4 + c] = pixels[i * 4 + c] }
            pixels[j * 4 + 3] = 255
            queue.append(j)
        }
    }
}
let result: CGImage = pixels.withUnsafeMutableBytes { raw in
    CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
try! NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("filled \(w)x\(h)")
