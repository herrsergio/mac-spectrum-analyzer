import SwiftUI

/// Main window: full-screen visualizer + a control bar that appears on hover.
/// Shows an error banner if capture fails.
struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: VisualizerSettings

    @State private var showControls = false
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VisualizerView(levels: model.levels, peaks: model.peaks, settings: settings)
                .ignoresSafeArea()

            // Error banner.
            if let error = model.errorMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error).lineLimit(3)
                        Spacer()
                        Button {
                            model.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .padding()
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Control bar (hover-reveal).
            if showControls {
                controlBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) { showControls = hovering }
        }
        .animation(.easeInOut(duration: 0.25), value: model.errorMessage)
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button {
                model.toggle()
            } label: {
                Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help(model.isRunning ? "Stop" : "Play")

            // Source picker. Flat sections render reliably; nested Menus can
            // come up empty on hover.
            Menu {
                Section("Output") {
                    Button {
                        model.select(source: .systemOutput)
                    } label: {
                        sourceLabel("System Output", selected: isSystemOutput)
                    }
                }

                Section("Input") {
                    if model.availableInputs.isEmpty {
                        Text("No microphones detected")
                    }
                    ForEach(model.availableInputs) { device in
                        Button {
                            model.select(source: .microphone(device))
                        } label: {
                            sourceLabel(device.name, selected: isSelectedInput(device))
                        }
                    }
                }

                if !model.availableProcesses.isEmpty {
                    Section("Specific App") {
                        ForEach(model.availableProcesses) { proc in
                            Button {
                                model.select(source: .process(proc))
                            } label: {
                                sourceLabel(proc.name, selected: isSelectedProcess(proc))
                            }
                        }
                    }
                }

                Divider()
                Button("Refresh Sources") { model.refreshSources() }
            } label: {
                Label(model.source.label, systemImage: "waveform")
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 200)

            Divider().frame(height: 20)

            // Quick theme switch.
            Picker("", selection: $settings.theme) {
                ForEach(VisualizerTheme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)
        .padding(.bottom, 24)
    }

    // MARK: - Source selection helpers

    private var isSystemOutput: Bool {
        if case .systemOutput = model.source { return true }
        return false
    }

    private func isSelectedInput(_ device: AudioInputDevice) -> Bool {
        if case .microphone(let d) = model.source { return d == device }
        return false
    }

    private func isSelectedProcess(_ proc: AudioProcessInfo) -> Bool {
        if case .process(let p) = model.source { return p == proc }
        return false
    }

    /// A menu row label with a checkmark when selected.
    @ViewBuilder
    private func sourceLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
