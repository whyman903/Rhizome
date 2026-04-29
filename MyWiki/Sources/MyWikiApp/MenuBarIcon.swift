import AppKit

enum MenuBarIcon {
    static let template: NSImage = makeTemplate()

    private static func makeTemplate() -> NSImage {
        // Sized to 22pt — the standard macOS menu bar height. Drawn as a
        // template (flat black with alpha) so the system tints it light/dark.
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Map the 1024-unit design space onto the rendered rect, with a y-flip
            // so the same top-down coordinates from the app icon work here too.
            let scale = rect.width / 1024
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: 1024)
            ctx.scaleBy(x: 1, y: -1)

            let nodeRadius: CGFloat = 65
            let nodes: [(x: CGFloat, y: CGFloat)] = [
                (380, 380),  // 0 main hub
                (640, 540),  // 1 secondary hub
                (200, 220),  // 2
                (600, 280),  // 3
                (280, 600),  // 4
                (820, 420),  // 5
                (780, 780),  // 6
                (500, 800),  // 7
            ]
            let edges: [(Int, Int)] = [
                (0, 2), (0, 3), (0, 4), (0, 1),
                (1, 5), (1, 6), (1, 7),
                (4, 7), (3, 5),
            ]

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(36)
            ctx.setLineCap(.round)

            for (a, b) in edges {
                ctx.beginPath()
                ctx.move(to: CGPoint(x: nodes[a].x, y: nodes[a].y))
                ctx.addLine(to: CGPoint(x: nodes[b].x, y: nodes[b].y))
                ctx.strokePath()
            }
            for n in nodes {
                ctx.fillEllipse(in: CGRect(
                    x: n.x - nodeRadius, y: n.y - nodeRadius,
                    width: nodeRadius * 2, height: nodeRadius * 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
