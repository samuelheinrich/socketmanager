import AppKit
import SwiftUI

enum InterfaceColors {
    // Fixed HSL tokens keep small colored text legible in both appearances.
    static let port = adaptive(light: hsl(355, 0.72, 0.38), dark: hsl(355, 0.94, 0.74))
    static let link = adaptive(light: hsl(212, 0.90, 0.36), dark: hsl(210, 1.00, 0.72))
    static let application = adaptive(light: hsl(263, 0.64, 0.40), dark: hsl(263, 0.86, 0.80))

    private static func hsl(_ hue: CGFloat, _ saturation: CGFloat, _ lightness: CGFloat) -> NSColor {
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        return NSColor(calibratedHue: hue / 360, saturation: hsbSaturation, brightness: brightness, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
