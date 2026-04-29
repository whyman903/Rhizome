#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Renders the "Asymmetric" knowledge-graph icon — dark warm background with a
// large hub at upper-left, a secondary hub at center-right, and 6 satellites
// connected by warm gold edges with soft halos.
//
// Output: writes a full iconset, runs iconutil, replaces both AppIcon.icns
// locations in the repo.

struct Node {
    let x: CGFloat
    let y: CGFloat
    let r: CGFloat   // solid core radius
    let glow: CGFloat // halo radius
}

// Coordinates are in the canonical 1024×1024 design space.
let nodes: [Node] = [
    Node(x: 380, y: 380, r: 84, glow: 200),  // 0 main hub
    Node(x: 640, y: 540, r: 64, glow: 160),  // 1 secondary hub
    Node(x: 200, y: 220, r: 40, glow: 100),  // 2
    Node(x: 600, y: 280, r: 40, glow: 100),  // 3
    Node(x: 280, y: 600, r: 40, glow: 100),  // 4
    Node(x: 820, y: 420, r: 40, glow: 100),  // 5
    Node(x: 780, y: 780, r: 40, glow: 100),  // 6
    Node(x: 500, y: 800, r: 40, glow: 100),  // 7
]

let edges: [(Int, Int)] = [
    (0, 2), (0, 3), (0, 4), (0, 1),
    (1, 5), (1, 6), (1, 7),
    (4, 7), (3, 5),
]

let bgInner = CGColor(srgbRed: 0x2a/255, green: 0x1a/255, blue: 0x0e/255, alpha: 1)
let bgOuter = CGColor(srgbRed: 0x0a/255, green: 0x06/255, blue: 0x04/255, alpha: 1)
let edgeColor = CGColor(srgbRed: 0xa0/255, green: 0x70/255, blue: 0xd4/255, alpha: 0.85)
let nodeBright = CGColor(srgbRed: 0xf2/255, green: 0xe4/255, blue: 0xff/255, alpha: 1)
let nodeMid = CGColor(srgbRed: 0xc0/255, green: 0x80/255, blue: 0xff/255, alpha: 1)
let nodeOuter = CGColor(srgbRed: 0x50/255, green: 0x20/255, blue: 0xa0/255, alpha: 0.3)
let glowColor = CGColor(srgbRed: 0xb8/255, green: 0x60/255, blue: 0xff/255, alpha: 0.7)
let glowFade = CGColor(srgbRed: 0xb8/255, green: 0x60/255, blue: 0xff/255, alpha: 0)

func render(size: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Map 1024-design coords into the bitmap. CGContext is bottom-left origin —
    // flip Y so the 1024-space "y down" coords match.
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // macOS rounded-square icon mask (≈22% radius).
    let cornerRadius: CGFloat = 225
    let bgRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let mask = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(mask)
    ctx.clip()

    // Background radial gradient.
    let bgGrad = CGGradient(
        colorsSpace: cs,
        colors: [bgInner, bgOuter] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        bgGrad,
        startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 512), endRadius: 720,
        options: .drawsAfterEndLocation
    )

    // Edges.
    ctx.setStrokeColor(edgeColor)
    ctx.setLineWidth(11)
    ctx.setLineCap(.round)
    for (a, b) in edges {
        let n1 = nodes[a]
        let n2 = nodes[b]
        ctx.beginPath()
        ctx.move(to: CGPoint(x: n1.x, y: n1.y))
        ctx.addLine(to: CGPoint(x: n2.x, y: n2.y))
        ctx.strokePath()
    }

    // Halos (drawn before cores so cores sit on top crisply).
    let glowGrad = CGGradient(
        colorsSpace: cs,
        colors: [glowColor, glowFade] as CFArray,
        locations: [0, 1]
    )!
    for n in nodes {
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: n.x, y: n.y), startRadius: 0,
            endCenter: CGPoint(x: n.x, y: n.y), endRadius: n.glow,
            options: []
        )
    }

    // Node cores: 3-stop radial gradient (bright center → amber → faded edge).
    let coreGrad = CGGradient(
        colorsSpace: cs,
        colors: [nodeBright, nodeMid, nodeOuter] as CFArray,
        locations: [0, 0.45, 1]
    )!
    for n in nodes {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: n.x - n.r, y: n.y - n.r, width: n.r * 2, height: n.r * 2))
        ctx.clip()
        ctx.drawRadialGradient(
            coreGrad,
            startCenter: CGPoint(x: n.x, y: n.y), startRadius: 0,
            endCenter: CGPoint(x: n.x, y: n.y), endRadius: n.r,
            options: []
        )
        ctx.restoreGState()
    }

    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

// MARK: - main

let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptPath.deletingLastPathComponent().deletingLastPathComponent()
let supportIcns = repoRoot.appendingPathComponent("MyWiki/support/AppIcon.icns")
let resourceIcns = repoRoot.appendingPathComponent("MyWiki/Sources/MyWikiApp/Resources/AppIcon.icns")
let workDir = repoRoot.appendingPathComponent("dist/icon-build")
let iconset = workDir.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: workDir)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// macOS iconset entries: (filename, pixel size).
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in entries {
    let img = render(size: px)
    try writePNG(img, to: iconset.appendingPathComponent(name))
    print("rendered \(name) (\(px)px)")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
let outIcns = workDir.appendingPathComponent("AppIcon.icns")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outIcns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed (status \(iconutil.terminationStatus))\n", stderr)
    exit(1)
}

for dest in [supportIcns, resourceIcns] {
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.copyItem(at: outIcns, to: dest)
    print("wrote \(dest.path)")
}

print("done.")
