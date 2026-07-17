import SwiftUI

/// Settings sheet.
struct SettingsView: View {
    @ObservedObject var settings: VisualizerSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(VisualizerTheme.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Colors", selection: $settings.colorScheme) {
                        ForEach(ColorScheme.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("Spectrum") {
                    Stepper(value: $settings.barCount, in: 8...256, step: 8) {
                        Text("Bars: \(settings.barCount)")
                    }
                    VStack(alignment: .leading) {
                        Text("Smoothing: \(settings.smoothing, specifier: "%.2f")")
                        Slider(value: $settings.smoothing, in: 0...1)
                    }
                    VStack(alignment: .leading) {
                        Text("Sensitivity: \(settings.sensitivity, specifier: "%.2f")")
                        Slider(value: $settings.sensitivity, in: 0.5...4.0)
                    }
                    Toggle("Peak hold", isOn: $settings.peakHold)
                    if settings.peakHold {
                        VStack(alignment: .leading) {
                            Text("Peak hold time: \(settings.peakHoldTime, specifier: "%.1f") s")
                            Slider(value: $settings.peakHoldTime, in: 0...3)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 360, height: 420)
    }
}
