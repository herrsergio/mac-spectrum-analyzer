import SwiftUI
import Combine

/// Persistent visualizer settings (UserDefaults).
final class VisualizerSettings: ObservableObject {
    @Published var theme: VisualizerTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var colorScheme: ColorScheme {
        didSet { defaults.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }
    /// Number of frequency bands (bars).
    @Published var barCount: Int {
        didSet { defaults.set(barCount, forKey: Keys.barCount) }
    }
    /// Smoothing 0...1. Higher = slower/more fluid.
    @Published var smoothing: Double {
        didSet { defaults.set(smoothing, forKey: Keys.smoothing) }
    }
    /// Sensitivity (gain) applied to the levels. 0.5...4.0
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: Keys.sensitivity) }
    }
    /// Show the "peak caps" that fall slowly.
    @Published var peakHold: Bool {
        didSet { defaults.set(peakHold, forKey: Keys.peakHold) }
    }
    /// Time (seconds) the peak cap stays at the maximum before falling.
    @Published var peakHoldTime: Double {
        didSet { defaults.set(peakHoldTime, forKey: Keys.peakHoldTime) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let theme = "theme"
        static let colorScheme = "colorScheme"
        static let barCount = "barCount"
        static let smoothing = "smoothing"
        static let sensitivity = "sensitivity"
        static let peakHold = "peakHold"
        static let peakHoldTime = "peakHoldTime"
    }

    init() {
        let d = UserDefaults.standard
        // Register default values on first launch.
        d.register(defaults: [
            Keys.barCount: 64,
            Keys.smoothing: 0.6,
            Keys.sensitivity: 1.5,
            Keys.peakHold: true,
            Keys.peakHoldTime: 1.0
        ])

        self.theme = VisualizerTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .bars
        self.colorScheme = ColorScheme(rawValue: d.string(forKey: Keys.colorScheme) ?? "") ?? .classic
        self.barCount = max(8, min(256, d.integer(forKey: Keys.barCount)))
        self.smoothing = d.double(forKey: Keys.smoothing)
        self.sensitivity = d.double(forKey: Keys.sensitivity)
        self.peakHold = d.bool(forKey: Keys.peakHold)
        self.peakHoldTime = d.double(forKey: Keys.peakHoldTime)
    }
}
