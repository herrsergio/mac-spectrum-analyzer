import SwiftUI

/// Drawing styles for the visualizer.
enum VisualizerTheme: String, CaseIterable, Identifiable, Codable {
    case bars
    case mirror
    case circular
    case line

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bars: return "Bars"
        case .mirror: return "Mirror"
        case .circular: return "Circular"
        case .line: return "Line"
        }
    }
}

/// Color palettes. They compute the color of a bar from its normalized height
/// (0...1) and its horizontal position (0...1).
enum ColorScheme: String, CaseIterable, Identifiable, Codable {
    case classic      // green -> yellow -> red (Winamp style)
    case ice          // blue -> cyan -> white
    case fire         // red -> orange -> yellow
    case rainbow      // hue by horizontal position
    case mono         // gray/white by height

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return "Classic"
        case .ice: return "Ice"
        case .fire: return "Fire"
        case .rainbow: return "Rainbow"
        case .mono: return "Mono"
        }
    }

    /// Returns the color for a bar given its height and position.
    func color(height: Double, position: Double) -> Color {
        let h = max(0, min(1, height))
        let p = max(0, min(1, position))

        switch self {
        case .classic:
            // Green at the base, yellow in the middle, red at the peak.
            if h < 0.5 {
                return lerp(Color(red: 0.1, green: 0.9, blue: 0.2),
                            Color(red: 0.95, green: 0.9, blue: 0.1),
                            t: h / 0.5)
            } else {
                return lerp(Color(red: 0.95, green: 0.9, blue: 0.1),
                            Color(red: 0.95, green: 0.15, blue: 0.1),
                            t: (h - 0.5) / 0.5)
            }
        case .ice:
            return lerp(Color(red: 0.0, green: 0.3, blue: 0.8),
                        Color(red: 0.85, green: 0.98, blue: 1.0),
                        t: h)
        case .fire:
            return lerp(Color(red: 0.5, green: 0.0, blue: 0.0),
                        Color(red: 1.0, green: 0.85, blue: 0.2),
                        t: h)
        case .rainbow:
            return Color(hue: p, saturation: 0.85, brightness: 0.6 + 0.4 * h)
        case .mono:
            let v = 0.35 + 0.65 * h
            return Color(red: v, green: v, blue: v)
        }
    }

    private func lerp(_ a: Color, _ b: Color, t: Double) -> Color {
        let ca = a.rgbaComponents
        let cb = b.rgbaComponents
        let tt = max(0, min(1, t))
        return Color(
            red: ca.r + (cb.r - ca.r) * tt,
            green: ca.g + (cb.g - ca.g) * tt,
            blue: ca.b + (cb.b - ca.b) * tt
        )
    }
}

extension Color {
    /// Approximate RGBA components via NSColor (sRGB space).
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.white
        return (Double(ns.redComponent), Double(ns.greenComponent),
                Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}
