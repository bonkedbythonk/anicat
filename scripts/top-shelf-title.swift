// Sets "Anicat" and its subtitle over a Top Shelf background rendered by
// build-brand-assets.sh. In Swift because the lettering is SF Pro, the app's
// face, and rsvg-convert cannot reach it: fontconfig sees only the hidden
// ".SF NS" families.
//
// swift top-shelf-title.swift <background.png> <out.png> <text-x> <scale>
import AppKit

let args = CommandLine.arguments
let background = NSBitmapImageRep(data: NSImage(contentsOfFile: args[1])!.tiffRepresentation!)!
let textX = CGFloat(Double(args[3])!)
let scale = CGFloat(Double(args[4])!)
let width = background.pixelsWide, height = background.pixelsHigh

let out = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
background.draw(in: NSRect(x: 0, y: 0, width: width, height: height))

let size = 170 * scale
let washi = NSColor(srgbRed: 0xf1 / 255.0, green: 0xec / 255.0, blue: 0xe2 / 255.0, alpha: 1)
let indigoDark = NSColor(srgbRed: 0x8f / 255.0, green: 0xb8 / 255.0, blue: 0xdc / 255.0, alpha: 1)
let title = NSAttributedString(string: "Anicat", attributes: [
    .font: NSFont.systemFont(ofSize: size, weight: .bold),
    .foregroundColor: washi,
    .kern: -size * 0.02,
])
// Baselines measured from the top, as in the SVG the background came from.
let titleTop = 330 * scale - size * 0.6
title.draw(at: NSPoint(x: textX * scale, y: CGFloat(height) - titleTop - size * 1.2))
let subtitle = NSAttributedString(string: "Anime, films and TV", attributes: [
    .font: NSFont.systemFont(ofSize: size * 0.24, weight: .medium),
    .foregroundColor: indigoDark,
])
subtitle.draw(at: NSPoint(x: textX * scale + 6 * scale, y: CGFloat(height) - titleTop - size * 1.2 - size * 0.30))
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
