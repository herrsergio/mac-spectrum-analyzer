# Spectrum Visualizer

A native macOS spectrum analyzer with Winamp-style frequency bars. It captures
**system audio output**, a **microphone/input device**, or a **specific app**
like Spotify, runs a live FFT, and renders the spectrum with switchable themes
and color schemes.

Built with SwiftUI + Accelerate/vDSP + CoreAudio process taps + AVAudioEngine.

## Features

- **Live audio capture** of system output or a single app, via CoreAudio
  process taps (no virtual audio device required).
- **Microphone / input capture** of any connected input device (built-in or
  external), via AVAudioEngine.
- **Real-time FFT** (2048-point, Hann window) grouped into log-spaced
  frequency bands.
- **Four visualizer themes**: bars, mirror, circular, line.
- **Five color schemes**: classic (Winamp green→yellow→red), ice, fire,
  rainbow, mono.
- **Peak hold** with an adjustable hold time — caps stay at the max for a set
  number of seconds before falling.
- **Tunable**: bar count, smoothing, sensitivity, peak-hold time. All settings
  persist across launches (`UserDefaults`).
- Full-bleed window with a hover-reveal control bar.

## Requirements

- **macOS 14.2+** — uses the CoreAudio process-tap API
  (`AudioHardwareCreateProcessTap`), unavailable before 14.2.
- Swift toolchain. **Command Line Tools is enough; full Xcode is not required.**

## Build & run

```sh
./build.sh                          # swift build -c release, then assemble a signed .app
open "build/Spectrum Visualizer.app"
```

`build.sh` compiles the SPM executable, copies `Resources/Info.plist` into the
bundle, and ad-hoc code-signs with `Resources/SpectrumVisualizer.entitlements`.

If you have full Xcode, you can also open the package directly:

```sh
open Package.swift
```

## Permissions

On first capture, macOS prompts for **microphone / audio recording** permission
(System Settings → Privacy & Security). This applies to both system-output taps
and microphone capture. Without it, capture fails and the error surfaces in the
app's UI banner. Grant it, then press play again.

> An ad-hoc-signed app moved between machines may be blocked by Gatekeeper or
> enterprise security policy. On the target machine you may need to allow it in
> System Settings → Privacy & Security, or re-sign with a valid Developer ID.

## Usage

1. Launch the app and start playing audio (Music, a browser, etc), or pick a
   microphone to visualize live input.
2. Hover near the bottom of the window to reveal the control bar.
3. Press **play**, pick a **source** from the menu — grouped into **Output**
   (System Output), **Input** (your microphones), and **Specific App** — and
   choose a **theme**. Use **Refresh Sources** to re-scan devices and apps.
4. Open **Settings** (gear icon) to adjust bars, smoothing, sensitivity, color
   scheme, and peak-hold time.

## Architecture

Signal flow: `AudioCapture` → `AppModel` (`SpectrumProcessor`) →
`SpectrumAnalyzer` → smoothing/peak-hold → `VisualizerView`.

| File | Responsibility |
|------|----------------|
| `AudioCapture.swift` | For system/app sources: creates a CoreAudio process tap, wraps it in a private aggregate device, installs an IO proc. For microphone sources: uses AVAudioEngine pointed at the chosen input device (requesting mic permission first). Delivers mono audio either way. Enumerates audio-producing processes and input devices for the source picker. |
| `SpectrumAnalyzer.swift` | Accumulates a 2048-point frame, applies a Hann window, runs a real FFT (vDSP), converts to magnitude, groups into log-spaced bands normalized 0…1 (−80 dB floor). |
| `AppModel.swift` | `ObservableObject` coordinator. Owns capture + an off-main-thread `SpectrumProcessor` that applies fast-attack/slow-decay smoothing and time-based peak-hold, then publishes `levels`/`peaks` on the main thread. |
| `Theme.swift` | `VisualizerTheme` and `ColorScheme` enums; schemes compute a bar color from normalized height + horizontal position. |
| `VisualizerSettings.swift` | `ObservableObject` persisted to `UserDefaults`. |
| `VisualizerView.swift` | SwiftUI `Canvas` renderer for all four themes. |
| `ContentView.swift` | Main window: full-bleed visualizer + hover control bar + error banner. |
| `SettingsView.swift` | Settings sheet. |
| `SpectrumVisualizerApp.swift` | `@main` App; single hidden-title-bar window. |

### Concurrency

The real-time audio thread never blocks: the FFT and smoothing run on
`SpectrumProcessor`'s serial queue, and all published UI state is dispatched to
the main thread. The processor is a separate non-`@MainActor` type so its
buffers can be mutated off-thread without data races under Swift strict
concurrency.

## Project layout

```
.
├── Package.swift              # executable target, macOS 14.2 pinned
├── build.sh                   # build + assemble + sign .app
├── Resources/
│   ├── Info.plist
│   └── SpectrumVisualizer.entitlements
└── Sources/SpectrumVisualizer/
    ├── SpectrumVisualizerApp.swift
    ├── ContentView.swift
    ├── VisualizerView.swift
    ├── SettingsView.swift
    ├── AppModel.swift
    ├── AudioCapture.swift
    ├── SpectrumAnalyzer.swift
    ├── Theme.swift
    └── VisualizerSettings.swift
```
