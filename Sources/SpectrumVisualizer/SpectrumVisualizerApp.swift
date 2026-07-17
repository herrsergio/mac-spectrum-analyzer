import SwiftUI

@main
struct SpectrumVisualizerApp: App {
    @StateObject private var settings: VisualizerSettings
    @StateObject private var model: AppModel

    init() {
        let s = VisualizerSettings()
        _settings = StateObject(wrappedValue: s)
        _model = StateObject(wrappedValue: AppModel(settings: s))
    }

    var body: some Scene {
        Window("Spectrum Visualizer", id: "main") {
            ContentView(model: model, settings: settings)
                .frame(minWidth: 480, minHeight: 300)
                .background(Color.black)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 500)
    }
}
