import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import AppKit
import OSLog

/// An audio process that can be visualized (for the source picker).
struct AudioProcessInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let name: String
}

/// An audio input device (microphone) available for capture.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Selected capture source.
enum CaptureSource: Hashable {
    case systemOutput                 // All system audio.
    case microphone(AudioInputDevice) // A specific input device.
    case process(AudioProcessInfo)    // A specific process.

    var label: String {
        switch self {
        case .systemOutput: return "System Output"
        case .microphone(let d): return d.name
        case .process(let p): return p.name
        }
    }
}

/// Capture errors, readable for the UI.
enum CaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case formatUnavailable
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            return "Could not create the process tap (status \(s)). Grant audio recording permission and try again."
        case .aggregateCreationFailed(let s):
            return "Could not create the aggregate device (status \(s))."
        case .ioProcFailed(let s):
            return "Could not start the IO proc (status \(s))."
        case .formatUnavailable:
            return "Could not read the tap format."
        case .permissionDenied:
            return "Microphone access denied. Grant it in System Settings and try again."
        }
    }
}

/// Creates a CoreAudio process tap, wraps it in a private aggregate device,
/// installs an IO proc, and delivers audio mixed down to mono.
final class AudioCapture {
    private let log = Logger(subsystem: "com.local.spectrumvisualizer", category: "AudioCapture")

    /// Callback with mono samples. Called on the audio thread: do not block.
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?
    /// Called once the real tap format is known.
    var onFormat: ((Double) -> Void)?

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    // Engine for microphone capture (the process-tap path does not do input).
    private var micEngine: AVAudioEngine?

    private var streamDescription: AudioStreamBasicDescription?
    private var monoScratch = [Float](repeating: 0, count: 8192)

    // MARK: - Process enumeration

    /// Lists processes that produce audio, for the source picker.
    static func audioProcesses() -> [AudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids)
        guard status == noErr else { return [] }

        let selfPID = getpid()
        var result: [AudioProcessInfo] = []
        for pidObject in ids {
            let pid = processPID(pidObject)
            guard pid > 0, pid != selfPID else { continue }
            // Only apps with a readable name: anonymous processes ("PID nnnn")
            // and helpers that are not user-facing apps are skipped.
            guard let name = processName(pid: pid) else { continue }
            result.append(AudioProcessInfo(id: pidObject, pid: pid, name: name))
        }
        // Únicos por nombre, ordenados.
        var seen = Set<String>()
        return result
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func processPID(_ obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid)
        return status == noErr ? pid : -1
    }

    private static func processName(pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.localizedName ?? app.bundleIdentifier
        }
        return nil
    }

    // MARK: - Input device enumeration

    /// Lists audio input devices (microphones) for the source picker.
    static func inputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids)
        guard status == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for dev in ids {
            guard inputChannelCount(dev) > 0 else { continue }
            let name = deviceName(dev) ?? "Device \(dev)"
            let uid = deviceUID(dev) ?? "\(dev)"
            result.append(AudioInputDevice(id: dev, uid: uid, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Number of input channels on a device (0 means it is output-only).
    private static func inputChannelCount(_ dev: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let ablPtr = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buf in ablPtr { channels += Int(buf.mNumberChannels) }
        return channels
    }

    private static func deviceName(_ dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (name as String) : nil
    }

    private static func deviceUID(_ dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (uid as String) : nil
    }

    // MARK: - Lifecycle

    func start(source: CaptureSource) throws {
        stop()

        // The microphone uses AVAudioEngine; everything else uses process taps.
        if case .microphone(let device) = source {
            try startMicrophone(device: device)
            return
        }

        // 1) Tap description.
        let tapDescription: CATapDescription
        switch source {
        case .systemOutput:
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .process(let p):
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [p.id])
        case .microphone:
            return  // Already handled above.
        }
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        // 2) Create the tap.
        var newTap: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard status == noErr, newTap != 0 else {
            throw CaptureError.tapCreationFailed(status)
        }
        tapID = newTap

        // 3) Read the real tap format.
        guard let format = readTapFormat(tapID) else {
            cleanup()
            throw CaptureError.formatUnavailable
        }
        streamDescription = format
        onFormat?(format.mSampleRate)

        // 4) Create a private aggregate device that contains the tap.
        let aggUID = "com.local.spectrumvisualizer.agg.\(getpid())"
        let tapUUID = tapDescription.uuid.uuidString
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "SpectrumVisualizerAggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]

        var newAgg: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAgg)
        guard status == noErr, newAgg != 0 else {
            cleanup()
            throw CaptureError.aggregateCreationFailed(status)
        }
        aggregateID = newAgg

        // 5) Install the IO proc.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] (_, inInputData, _, _, _) in
            self?.handleInput(inInputData)
        }
        guard status == noErr, ioProcID != nil else {
            cleanup()
            throw CaptureError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            throw CaptureError.ioProcFailed(status)
        }

        running = true
        log.info("Captura iniciada: \(source.label, privacy: .public)")
    }

    /// Captures from a specific input device (microphone) via AVAudioEngine.
    private func startMicrophone(device: AudioInputDevice) throws {
        // Microphone access must be granted before the engine can read input.
        guard requestMicrophonePermission() else {
            throw CaptureError.permissionDenied
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Point the engine's input unit at the chosen device.
        do {
            var deviceID = device.id
            let unit = input.audioUnit
            if let unit {
                let status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr {
                    log.error("Failed to set input device (status \(status))")
                }
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.formatUnavailable }

        onFormat?(format.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handlePCMBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.ioProcFailed(-1)
        }

        micEngine = engine
        running = true
        log.info("Capture started: \(device.name, privacy: .public)")
    }

    /// Requests microphone permission synchronously (blocks until resolved).
    private func requestMicrophonePermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            return granted
        default:
            return false
        }
    }

    /// Mixes an AVAudioPCMBuffer (float, non-interleaved) down to mono. Do not block.
    private func handlePCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)

        if monoScratch.count < frames {
            monoScratch = [Float](repeating: 0, count: frames)
        }

        monoScratch.withUnsafeMutableBufferPointer { dst in
            if channels == 1 {
                dst.baseAddress!.update(from: channelData[0], count: frames)
            } else {
                // Non-interleaved: average channels -> mono.
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += channelData[c][f] }
                    dst[f] = sum / Float(channels)
                }
            }
        }

        monoScratch.withUnsafeBufferPointer { ptr in
            onSamples?(ptr.baseAddress!, frames)
        }
    }

    func stop() {
        guard tapID != 0 || aggregateID != 0 || micEngine != nil else { return }
        cleanup()
        running = false
        log.info("Captura detenida")
    }

    private func cleanup() {
        // Microphone.
        if let engine = micEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            micEngine = nil
        }
        // Process tap + aggregate device.
        if let proc = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        streamDescription = nil
    }

    // MARK: - Audio thread

    /// Mixes the incoming buffer down to mono and delivers it. Do not block here.
    private func handleInput(_ bufferList: UnsafePointer<AudioBufferList>) {
        guard let format = streamDescription else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count > 0 else { return }

        let channels = max(1, Int(format.mChannelsPerFrame))
        let firstBuf = abl[0]
        guard let mData = firstBuf.mData else { return }

        let floatCount = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        let frames = floatCount / channels
        if frames <= 0 { return }

        if monoScratch.count < frames {
            monoScratch = [Float](repeating: 0, count: frames)
        }

        let src = mData.assumingMemoryBound(to: Float.self)

        if channels == 1 {
            monoScratch.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src, count: frames)
            }
        } else {
            // Interleaved: average channels -> mono.
            monoScratch.withUnsafeMutableBufferPointer { dst in
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels {
                        sum += src[f * channels + c]
                    }
                    dst[f] = sum / Float(channels)
                }
            }
        }

        monoScratch.withUnsafeBufferPointer { ptr in
            onSamples?(ptr.baseAddress!, frames)
        }
    }

    // MARK: - Formato del tap

    private func readTapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd
    }
}
