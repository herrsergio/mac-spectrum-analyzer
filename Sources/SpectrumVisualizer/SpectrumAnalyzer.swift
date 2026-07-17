import Foundation
import Accelerate

/// Converts audio samples into log-spaced frequency bands (0...1).
///
/// Accumulates samples until a frame of `fftSize` points is filled, applies a
/// Hann window, runs a real FFT (vDSP), converts to magnitude, and groups the
/// bins into `bandCount` log-spaced bands normalized against a -80 dB floor.
final class SpectrumAnalyzer {
    let fftSize: Int
    private let log2n: vDSP_Length
    private let halfSize: Int
    private var fftSetup: FFTSetup

    private var sampleRate: Double

    // Circular buffer for sample accumulation.
    private var frame: [Float]
    private var fillCount = 0

    // Precomputed Hann window.
    private var window: [Float]

    // Working buffers for the FFT.
    private var realp: [Float]
    private var imagp: [Float]
    private var windowed: [Float]
    private var magnitudes: [Float]

    private let minFrequency: Double = 30.0
    private let floorDB: Float = -80.0

    init(fftSize: Int = 2048, sampleRate: Double = 48_000) {
        precondition((fftSize & (fftSize - 1)) == 0, "fftSize must be a power of 2")
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.sampleRate = sampleRate

        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        self.frame = [Float](repeating: 0, count: fftSize)
        self.window = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: halfSize)
        self.imagp = [Float](repeating: 0, count: halfSize)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.magnitudes = [Float](repeating: 0, count: halfSize)

        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func updateSampleRate(_ rate: Double) {
        guard rate > 0 else { return }
        sampleRate = rate
    }

    /// Accumulates mono samples. Returns a new set of bands when a frame is
    /// completed, or nil if there are not yet enough samples.
    func process(samples: UnsafePointer<Float>, count: Int, bandCount: Int) -> [Float]? {
        var produced: [Float]? = nil
        var offset = 0

        while offset < count {
            let need = fftSize - fillCount
            let avail = count - offset
            let take = min(need, avail)

            frame.withUnsafeMutableBufferPointer { dst in
                (dst.baseAddress! + fillCount).update(from: samples + offset, count: take)
            }
            fillCount += take
            offset += take

            if fillCount == fftSize {
                produced = computeBands(bandCount: bandCount)
                fillCount = 0
            }
        }
        return produced
    }

    /// Runs the FFT over the current frame and groups it into bands.
    private func computeBands(bandCount: Int) -> [Float] {
        // Apply Hann window.
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack as split complex and transform to frequency.
        magnitudes.withUnsafeMutableBufferPointer { magPtr in
            realp.withUnsafeMutableBufferPointer { realPtr in
                imagp.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                                imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfSize))
                        }
                    }
                    // Forward real FFT.
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // Magnitude (squared modulus) per bin.
                    vDSP_zvmags(&split, 1, magPtr.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }

        // Scale and convert to dB. vDSP_zvmags gives |X|^2; we normalize.
        var scale = Float(1.0 / Float(fftSize * fftSize))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))

        // Group into log-spaced bands.
        return groupIntoBands(bandCount: bandCount)
    }

    private func groupIntoBands(bandCount: Int) -> [Float] {
        var bands = [Float](repeating: 0, count: bandCount)
        let nyquist = sampleRate / 2.0
        let maxFreq = nyquist
        let minF = max(minFrequency, sampleRate / Double(fftSize))

        let binHz = sampleRate / Double(fftSize)
        let logMin = log10(minF)
        let logMax = log10(maxFreq)
        let logRange = logMax - logMin

        for b in 0..<bandCount {
            // Log frequency range for this band.
            let f0 = pow(10, logMin + logRange * Double(b) / Double(bandCount))
            let f1 = pow(10, logMin + logRange * Double(b + 1) / Double(bandCount))

            var bin0 = Int((f0 / binHz).rounded(.down))
            var bin1 = Int((f1 / binHz).rounded(.up))
            bin0 = max(1, min(halfSize - 1, bin0))
            bin1 = max(bin0 + 1, min(halfSize, bin1))

            // Energy peak in the range (livelier than the average).
            var peak: Float = 0
            for i in bin0..<bin1 {
                if magnitudes[i] > peak { peak = magnitudes[i] }
            }

            // Power -> dB, then normalize against the floor.
            let db = 10 * log10(max(peak, 1e-12))
            var norm = (db - floorDB) / (0 - floorDB)   // -80..0 dB -> 0..1
            norm = max(0, min(1, norm))
            bands[b] = norm
        }
        return bands
    }
}
