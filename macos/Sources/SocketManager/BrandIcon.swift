import AppKit

@MainActor
enum BrandIcon {
    static func image(size: CGFloat, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            draw(in: bounds, template: template)
            return true
        }
        image.isTemplate = template
        return image
    }

    private static func draw(in bounds: NSRect, template: Bool) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.minX, yBy: bounds.minY)
        transform.scaleX(by: bounds.width / 1024, yBy: bounds.height / 1024)
        transform.concat()

        if !template {
            let square = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 208, yRadius: 208)
            let navy = NSColor(calibratedHue: 0.64, saturation: 0.76, brightness: 0.28, alpha: 1)
            let blue = NSColor(calibratedHue: 0.60, saturation: 0.88, brightness: 0.66, alpha: 1)
            NSGradient(starting: navy, ending: blue)!.draw(in: square, angle: 50)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            square.lineWidth = 8
            square.stroke()
        }

        let circuit = NSBezierPath()
        circuit.lineWidth = template ? 88 : 68
        circuit.lineCapStyle = .round
        circuit.lineJoinStyle = .round
        circuit.move(to: NSPoint(x: 292, y: 724))
        circuit.line(to: NSPoint(x: 636, y: 724))
        circuit.curve(to: NSPoint(x: 748, y: 612), controlPoint1: NSPoint(x: 700, y: 724), controlPoint2: NSPoint(x: 748, y: 676))
        circuit.curve(to: NSPoint(x: 636, y: 500), controlPoint1: NSPoint(x: 748, y: 548), controlPoint2: NSPoint(x: 700, y: 500))
        circuit.line(to: NSPoint(x: 388, y: 500))
        circuit.curve(to: NSPoint(x: 276, y: 388), controlPoint1: NSPoint(x: 324, y: 500), controlPoint2: NSPoint(x: 276, y: 452))
        circuit.curve(to: NSPoint(x: 388, y: 276), controlPoint1: NSPoint(x: 276, y: 324), controlPoint2: NSPoint(x: 324, y: 276))
        circuit.line(to: NSPoint(x: 732, y: 276))
        (template ? NSColor.black : NSColor.white).setStroke()
        circuit.stroke()

        for (point, hue) in [(NSPoint(x: 292, y: 724), CGFloat(0.49)), (NSPoint(x: 732, y: 276), CGFloat(0.98))] {
            let node = NSBezierPath(ovalIn: NSRect(x: point.x - 72, y: point.y - 72, width: 144, height: 144))
            (template ? NSColor.black : NSColor(calibratedHue: hue, saturation: 0.60, brightness: 1, alpha: 1)).setFill()
            node.fill()
            if !template {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56)).fill()
            }
        }
    }

    static func exportIconset(to directory: URL) throws {
        let iconset = directory.appendingPathComponent("AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), template: false)
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
            }
        }
    }
}
