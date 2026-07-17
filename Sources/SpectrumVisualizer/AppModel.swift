import SwiftUI
import Combine
import AVFoundation

/// Processing engine off the main thread. Not actor-isolated; all its state is
/// touched only inside `queue`, avoiding data races.
private final class SpectrumProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.local.spectrumvisualizer.processing",
                                      qos: .userInteractive)
    private let analyzer = SpectrumAnalyzer()

    // State accessed only inside `queue`.
    private var smoothed: [Float]
    private var peakValues: [Float]
    // Frames remaining that each peak should stay at the maximum before falling.
    private var holdFramesLeft: [Int]
    private var barCount: Int
    private var sampleRate: Double = 48_000

    // Live scalar settings (read without a lock: intentional, cheap).
    var smoothing: Double = 0.6
    var sensitivity: Double = 1.5
    var peakHold: Bool = true
    // Time (seconds) the peak cap stays at the maximum before falling.
    var peakHoldTime: Double = 1.0

    /// Already-smoothed output, delivered on the main thread.
    var onOutput: (@Sendable ([Float], [Float]) -> Void)?

    init(barCount: Int) {
        self.barCount = barCount
        self.smoothed = [Float](repeating: 0, count: barCount)
        self.peakValues = [Float](repeating: 0, count: barCount)
        self.holdFramesLeft = [Int](repeating: 0, count: barCount)
    }

    func updateSampleRate(_ rate: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sampleRate = rate
            self.analyzer.updateSampleRate(rate)
        }
    }

    func setBarCount(_ n: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.barCount = n
            self.smoothed = [Float](repeating: 0, count: n)
            self.peakValues = [Float](repeating: 0, count: n)
            self.holdFramesLeft = [Int](repeating: 0, count: n)
            self.onOutput?(self.smoothed, self.peakValues)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.smoothed = [Float](repeating: 0, count: self.barCount)
            self.peakValues = [Float](repeating: 0, count: self.barCount)
            self.holdFramesLeft = [Int](repeating: 0, count: self.barCount)
            self.onOutput?(self.smoothed, self.peakValues)
        }
    }

    /// Called on the audio thread. Copies and dispatches.
    func ingest(_ ptr: UnsafePointer<Float>, _ count: Int) {
        let copy = Array(UnsafeBufferPointer(start: ptr, count: count))
        queue.async { [weak self] in self?.process(copy) }
    }

    private func process(_ samples: [Float]) {
        let n = barCount
        var bandsOut: [Float]? = nil
        samples.withUnsafeBufferPointer { bp in
            bandsOut = analyzer.process(samples: bp.baseAddress!, count: bp.count, bandCount: n)
        }
        guard let bands = bandsOut else { return }

        if smoothed.count != n {
            smoothed = [Float](repeating: 0, count: n)
            peakValues = [Float](repeating: 0, count: n)
            holdFramesLeft = [Int](repeating: 0, count: n)
        }

        let gain = Float(sensitivity)
        let decay = Float(0.85 + 0.14 * smoothing)        // 0.85...0.99
        let attack = Float(0.35 + 0.5 * (1 - smoothing))  // more responsive when smoothing is low
        let peakDecay: Float = 0.94

        // An FFT frame spans fftSize samples => frames/sec = sampleRate/fftSize.
        let frameRate = sampleRate / Double(analyzer.fftSize)
        let holdFrames = max(0, Int((peakHoldTime * frameRate).rounded()))

        for i in 0..<n {
            var v = min(1, bands[i] * gain)
            let prev = smoothed[i]
            v = (v > prev) ? prev + (v - prev) * attack : prev * decay
            smoothed[i] = v

            if peakHold {
                if v >= peakValues[i] {
                    // New peak: set it and reset the hold timer.
                    peakValues[i] = v
                    holdFramesLeft[i] = holdFrames
                } else if holdFramesLeft[i] > 0 {
                    // Stay at the maximum while time remains.
                    holdFramesLeft[i] -= 1
                } else {
                    // Time is up: fall.
                    peakValues[i] *= peakDecay
                }
            } else {
                peakValues[i] = 0
                holdFramesLeft[i] = 0
            }
        }
        onOutput?(smoothed, peakValues)
    }
}

/// Main coordinator. Owns the capture and the processing engine, and publishes
/// smoothed levels on the main thread.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var levels: [Float] = []
    @Published private(set) var peaks: [Float] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

    @Published var availableProcesses: [AudioProcessInfo] = []
    @Published var availableInputs: [AudioInputDevice] = []
    @Published var source: CaptureSource = .systemOutput

    private let settings: VisualizerSettings
    private let capture = AudioCapture()
    private let processor: SpectrumProcessor
    private var cancellables = Set<AnyCancellable>()

    init(settings: VisualizerSettings) {
        self.settings = settings
        self.processor = SpectrumProcessor(barCount: settings.barCount)
        self.levels = [Float](repeating: 0, count: settings.barCount)
        self.peaks = [Float](repeating: 0, count: settings.barCount)

        processor.smoothing = settings.smoothing
        processor.sensitivity = settings.sensitivity
        processor.peakHold = settings.peakHold
        processor.peakHoldTime = settings.peakHoldTime

        processor.onOutput = { [weak self] levels, peaks in
            Task { @MainActor in
                self?.levels = levels
                self?.peaks = peaks
            }
        }

        capture.onFormat = { [weak self] rate in
            self?.processor.updateSampleRate(rate)
        }
        capture.onSamples = { [weak self] ptr, count in
            self?.processor.ingest(ptr, count)
        }

        // Propagate settings changes to the processor.
        settings.$barCount.removeDuplicates()
            .sink { [weak self] n in self?.processor.setBarCount(n) }
            .store(in: &cancellables)
        settings.$smoothing
            .sink { [weak self] v in self?.processor.smoothing = v }
            .store(in: &cancellables)
        settings.$sensitivity
            .sink { [weak self] v in self?.processor.sensitivity = v }
            .store(in: &cancellables)
        settings.$peakHold
            .sink { [weak self] v in self?.processor.peakHold = v }
            .store(in: &cancellables)
        settings.$peakHoldTime
            .sink { [weak self] v in self?.processor.peakHoldTime = v }
            .store(in: &cancellables)

        refreshSources()
    }

    // MARK: - Control

    /// Refreshes both the audio-process list and the input-device list.
    func refreshSources() {
        availableProcesses = AudioCapture.audioProcesses()
        availableInputs = AudioCapture.inputDevices()
    }

    func start() {
        errorMessage = nil
        do {
            try capture.start(source: source)
            isRunning = true
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        capture.stop()
        isRunning = false
        processor.reset()
    }

    func toggle() { isRunning ? stop() : start() }

    func select(source newSource: CaptureSource) {
        let wasRunning = isRunning
        source = newSource
        if wasRunning { start() }   // start() does an internal stop() first.
    }
}
