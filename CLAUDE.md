# Spectrum Visualizer — Project Guide

Native macOS spectrum analyzer (Winamp-style frequency bars) that captures
**system audio output**, a **microphone/input device**, or a **specific app**
(e.g. Spotify) and renders a live FFT spectrum with switchable themes.
SwiftUI + Accelerate/vDSP + CoreAudio process taps + AVAudioEngine (mic).

## Requirements

- **macOS 14.2+** — uses the CoreAudio process-tap API (`AudioHardwareCreateProcessTap`).
- Swift toolchain (Command Line Tools is enough; full Xcode not required).
- The package deployment target is pinned to `macOS("14.2")` in `Package.swift`.
  Do NOT lower it to `.v14` — the tap APIs are unavailable before 14.2 and the
  build will fail with availability errors.

## Build & run

```sh
./build.sh                          # swift build -c release, then assemble a signed .app
open "build/Spectrum Visualizer.app"
```

`build.sh` compiles the SPM executable, copies `Resources/Info.plist` into the
bundle, and ad-hoc code-signs with `Resources/SpectrumVisualizer.entitlements`.

Alternatively, open in Xcode if available: `open Package.swift`.

## Permissions

On first capture, macOS prompts for **microphone / audio recording** permission
(System Settings → Privacy & Security). This covers both process taps and
microphone capture; mic capture explicitly requests it via
`AVCaptureDevice.requestAccess(for: .audio)` before starting the engine. Without
it, capture fails and the error surfaces in the app's UI banner. Grant it, then
press play again.

Note: an ad-hoc-signed app moved between machines may be blocked by Gatekeeper
or enterprise security policy. On the target machine you may need to allow it in
System Settings → Privacy & Security, or re-sign with a valid Developer ID.

## Architecture

Signal flow: `AudioCapture` → `AppModel` (`SpectrumProcessor`) →
`SpectrumAnalyzer` → smoothing/peak-hold → `AppModel` → `VisualizerView`.

- **`AudioCapture.swift`** — Two capture paths, chosen by `CaptureSource`:
  - *System output / specific app*: creates a CoreAudio process tap (system-wide
    via `CATapDescription(stereoGlobalTapButExcludeProcesses:)`, or per-app via
    `stereoMixdownOfProcesses:`), wraps it in a private aggregate device,
    installs an IO proc.
  - *Microphone (`AudioInputDevice`)*: uses `AVAudioEngine`, pointing the input
    node's audio unit at the chosen device via
    `kAudioOutputUnitProperty_CurrentDevice`, after requesting mic permission.
  Both deliver audio mixed down to mono. Enumerates audio-producing processes
  (`kAudioHardwarePropertyProcessObjectList`, named apps only) and input devices
  (`kAudioHardwarePropertyDevices` filtered by input channel count) for the
  source picker.
- **`SpectrumAnalyzer.swift`** — Accumulates samples to a 2048-point frame,
  applies a Hann window, runs a real FFT (vDSP), converts to amplitude, and
  groups bins into log-spaced frequency bands normalized to 0...1.
- **`AppModel.swift`** — `@MainActor ObservableObject` coordinator. Owns capture
  plus an off-main-thread `SpectrumProcessor` (its own serial queue, not actor-
  isolated) that runs the FFT, applies fast-attack/slow-decay smoothing and
  time-based peak-hold, and publishes `levels`/`peaks` on the main thread.
  Manages source selection (`refreshSources()` lists processes + inputs) and
  start/stop.
- **`VisualizerView.swift`** — SwiftUI `Canvas` renderer. Themes: `bars`,
  `mirror`, `circular`, `line`. Redraws when `levels` changes.
- **`Theme.swift`** — `VisualizerTheme` and `ColorScheme` enums; color schemes
  compute a bar color from normalized height + horizontal position.
- **`VisualizerSettings.swift`** — `ObservableObject` persisted to
  `UserDefaults`: theme, color scheme, bar count, smoothing, sensitivity,
  peak-hold, peak-hold time.
- **`ContentView.swift`** — Main window: full-bleed visualizer + a hover-reveal
  control bar (play/stop, source picker, theme, settings). The source picker
  uses flat `Section`s (Output / Input / Specific App) — nested `Menu`s render
  empty on hover, so avoid them. Error banner.
- **`SettingsView.swift`** — Settings sheet.
- **`SpectrumVisualizerApp.swift`** — `@main` App; wires shared `settings` +
  `model`, single window, hidden title bar.

## Conventions & gotchas

- Real-time audio thread must not block: the FFT + smoothing run on
  `SpectrumProcessor`'s serial `queue`; all `@Published` mutations are dispatched
  to the main thread. `SpectrumProcessor` is a separate `@unchecked Sendable`
  type (not `@MainActor`) precisely so its buffers can be mutated off-thread
  without tripping Swift strict-concurrency checks — keep this split.
- Reading scalar settings off the processing thread is intentional (cheap, live-
  tunable); don't add locking unless a real data race appears.
- The tap's stream format (sample rate, channel count) is read at start from
  `kAudioTapPropertyFormat` and passed through to the analyzer — don't hardcode
  48 kHz beyond the fallback. For mic capture the format comes from the input
  node's `outputFormat(forBus:)`.
- Bar count is runtime-adjustable; the processor re-sizes its smoothing/peak/
  hold buffers when `settings.barCount` changes.
- Peak-hold is time-based: `peakHoldTime` (seconds) is converted to frames via
  `sampleRate / fftSize`, so the cap holds for the same wall-clock time at any
  sample rate.
- Source picker must use flat `Section`s, not nested `Menu`s (the latter render
  empty on hover in SwiftUI on this macOS version).

## Status / likely next steps

Working: system-output, per-app, and microphone/input capture all verified on
real audio. Comments/strings are English throughout. Areas most likely to need
tuning: band normalization (`-80 dB` floor in `SpectrumAnalyzer`), smoothing
feel, and the exact permission/entitlement combo for taps on a given macOS
version. Possible features not yet built: menu-bar/always-on-top floating mode,
more themes, per-source auto-start, persisting the selected source across
launches.
