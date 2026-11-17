import Foundation
import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin

// A HAL device has an input bus (1) for capture and an output bus (0) for playback.
private let inputBus: AudioUnitElement = 1
private let outputBus: AudioUnitElement = 0
private let maxFramesPerSlice: UInt32 = 4_096

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw NSError(domain: "SyncDelay", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (OSStatus \(status))"]) }
}

private func atomicLoad(_ value: UnsafeMutablePointer<Int32>) -> UInt32 {
    UInt32(bitPattern: OSAtomicAdd32Barrier(0, value))
}

private func atomicStore(_ value: UnsafeMutablePointer<Int32>, _ newValue: UInt32) {
    // CAS is used as a release-store. Each location has exactly one writer.
    var old = OSAtomicAdd32Barrier(0, value)
    while !OSAtomicCompareAndSwap32Barrier(old, Int32(bitPattern: newValue), value) {
        old = OSAtomicAdd32Barrier(0, value)
    }
}

private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeUnretainedValue() as String?
}

private func allDevices() throws -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), "get device list size")
    var devices = Array(repeating: AudioDeviceID(), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices), "get device list")
    return devices
}

private func findDevice(_ query: String) throws -> (AudioDeviceID, String) {
    let deviceInfo = try allDevices().map { ($0, stringProperty($0, kAudioObjectPropertyName) ?? "Unknown", stringProperty($0, kAudioDevicePropertyDeviceUID) ?? "") }
    if let exact = deviceInfo.first(where: { $0.1 == query || $0.2 == query }) { return (exact.0, exact.1) }
    if let partial = deviceInfo.first(where: { $0.1.localizedCaseInsensitiveContains(query) }) { return (partial.0, partial.1) }
    let names = deviceInfo.map { "  \($0.1)  [\($0.2)]" }.joined(separator: "\n")
    throw NSError(domain: "SyncDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "No device matches '\(query)'. Available devices:\n\(names)"])
}

private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "get stream configuration size")
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, list), "get stream configuration")
    return withUnsafePointer(to: &list.pointee.mBuffers) { first in
        first.withMemoryRebound(to: AudioBuffer.self, capacity: Int(list.pointee.mNumberBuffers)) { buffers in
            (0..<Int(list.pointee.mNumberBuffers)).reduce(0) { $0 + buffers[$1].mNumberChannels }
        }
    }
}

private func bufferAt(_ list: UnsafeMutablePointer<AudioBufferList>, _ index: Int) -> AudioBuffer {
    withUnsafePointer(to: &list.pointee.mBuffers) { first in
        first.withMemoryRebound(to: AudioBuffer.self, capacity: Int(list.pointee.mNumberBuffers)) { $0[index] }
    }
}

private func pcmFormat(channels: UInt32, sampleRate: Double) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}

// SPSC frame ring. `read` is the dry head; the delayed head is `read - delayFrames`.
private final class AudioRing {
    let capacity: UInt32
    let mask: UInt32
    let samples: UnsafeMutablePointer<Float>
    let producerIndex = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    let consumerIndex = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    let delayFrames = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    let channelMask = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    let peaks = UnsafeMutablePointer<Int32>.allocate(capacity: 2) // Float bit patterns, L/R
    let gain = UnsafeMutablePointer<Int32>.allocate(capacity: 1) // Float bit pattern
    private var appliedGain: Float = 1 // consumer-only; ramps toward `gain` to avoid zipper noise
    let maxDelay: UInt32

    init(requestedDelay: UInt32, channelMask initialMask: UInt32) {
        capacity = 524_288 // power of two: about 10.9 sec at 48 kHz
        mask = capacity - 1
        maxDelay = capacity / 2 // reserves history even if the producer gets ahead
        samples = .allocate(capacity: Int(capacity) * 2)
        samples.initialize(repeating: 0, count: Int(capacity) * 2)
        producerIndex.initialize(to: 0); consumerIndex.initialize(to: 0); delayFrames.initialize(to: 0)
        channelMask.initialize(to: Int32(bitPattern: initialMask)); peaks.initialize(repeating: 0, count: 2); stats.initialize(repeating: 0, count: 4); gain.initialize(to: Int32(bitPattern: Float(1).bitPattern))
        setDelay(requestedDelay)
    }
    deinit { samples.deinitialize(count: Int(capacity) * 2); samples.deallocate(); producerIndex.deallocate(); consumerIndex.deallocate(); delayFrames.deallocate(); channelMask.deallocate(); peaks.deallocate(); gain.deallocate(); stats.deallocate() }

    func setDelay(_ frames: UInt32) { atomicStore(delayFrames, min(frames, maxDelay)) }
    func currentDelay() -> UInt32 { atomicLoad(delayFrames) }
    let stats = UnsafeMutablePointer<Int32>.allocate(capacity: 4) // 0 render errors, 1 underruns, 2 drops, 3 overruns
    func bump(_ i: Int) { _ = OSAtomicIncrement32Barrier(stats + i) }
    func setGain(_ value: Float) { atomicStore(gain, value.bitPattern) }
    func setChannelMask(_ mask: UInt32) { atomicStore(channelMask, mask) }
    func peak(_ channel: Int) -> Float { Float(bitPattern: atomicLoad(peaks + channel)) }
    /// Producer and consumer positions; the watchdog uses them to notice when audio stops flowing.
    func positions() -> (written: UInt32, read: UInt32) { (atomicLoad(producerIndex), atomicLoad(consumerIndex)) }

    // Producer: publish samples only after writing them. Keep maxDelay frames behind the dry head intact.
    func write(_ source: UnsafePointer<Float>, frames: UInt32) {
        var left: Float = 0, right: Float = 0
        for frame in 0..<Int(frames) { left = max(left, abs(source[frame * 2])); right = max(right, abs(source[frame * 2 + 1])) }
        atomicStore(peaks, left.bitPattern); atomicStore(peaks + 1, right.bitPattern)
        let write = atomicLoad(producerIndex), read = atomicLoad(consumerIndex)
        let used = write &- read
        let free = capacity &- used
        let allowed = free > maxDelay ? min(frames, free - maxDelay) : 0
        guard allowed == frames else { bump(3); if allowed == 0 { return }; return writeClamped(source, allowed, write) }
        writeClamped(source, allowed, write)
    }
    private func writeClamped(_ source: UnsafePointer<Float>, _ allowed: UInt32, _ write: UInt32) {
        for frame in 0..<allowed {
            let dest = Int((write &+ frame) & mask) * 2
            let src = Int(frame) * 2
            samples[dest] = source[src]; samples[dest + 1] = source[src + 1]
        }
        atomicStore(producerIndex, write &+ allowed)
    }

    // Consumer returns the number of real frames provided; the caller silences the rest.
    func read(into output: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> UInt32 {
        let write = atomicLoad(producerIndex)
        var read = atomicLoad(consumerIndex)
        var available = write &- read
        // Input and output clocks drift, and capture may start before playback. Drop any backlog so
        // the un-delayed channels stay close to real time instead of trailing by seconds.
        let target = frames &+ 512
        if available > max(frames &* 3, 4_096) { read = write &- target; available = target; bump(2) }
        let delayedMask = atomicLoad(channelMask)
        let startGain = appliedGain, endGain = Float(bitPattern: atomicLoad(gain))
        appliedGain = endGain
        let count = min(frames, available)
        if count < frames { bump(1) }
        let delay = currentDelay()
        var baseChannel: UInt32 = 0
        for bufferIndex in 0..<Int(output.pointee.mNumberBuffers) {
            let buffer = bufferAt(output, bufferIndex)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { baseChannel += buffer.mNumberChannels; continue }
            for frame in 0..<count {
                let dry = Int((read &+ frame) & mask) * 2
                let late = Int((read &+ frame &- delay) & mask) * 2
                let g = count > 0 ? startGain + (endGain - startGain) * Float(frame) / Float(count) : endGain
                for channel in 0..<buffer.mNumberChannels {
                    let index = baseChannel + channel
                    let pair = index < 32 && (delayedMask >> index) & 1 == 1 ? late : dry
                    data[Int(frame) * Int(buffer.mNumberChannels) + Int(channel)] = samples[pair + Int(channel & 1)] * g
                }
            }
            baseChannel += buffer.mNumberChannels
        }
        atomicStore(consumerIndex, read &+ count)
        return count
    }
}

// MARK: Equalizer

private let eqFrequencies: [Double] = [60, 150, 400, 1_000, 3_000, 8_000]
private let eqBandCount = 6

private struct EQPreset {
    let name: String
    let gains: [Double]
    static let all: [EQPreset] = [
        EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Bass Boost", gains: [6, 4, 0, 0, 0, 1]),
        EQPreset(name: "Vocal", gains: [-2, -1, 1, 3, 3, 1]),
        EQPreset(name: "Rock", gains: [4, 2, -1, 1, 3, 3]),
        EQPreset(name: "Electronic", gains: [5, 3, 0, -1, 2, 4]),
        EQPreset(name: "Acoustic", gains: [2, 1, 0, 1, 2, 2]),
        EQPreset(name: "Podcast", gains: [-4, -1, 2, 3, 2, -1]),
        EQPreset(name: "Late Night", gains: [-3, -1, 1, 2, 1, -2]),
    ]
}

/// Six-band stereo EQ (low shelf, four peaks, high shelf) plus a band analyzer for Auto EQ.
/// Runs on the capture thread; gains arrive from the main thread as atomic Float bit patterns.
private final class Equalizer {
    let sampleRate: Double
    let gains = UnsafeMutablePointer<Int32>.allocate(capacity: eqBandCount)
    let bandPower = UnsafeMutablePointer<Int32>.allocate(capacity: eqBandCount)
    let enabled = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    let version = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var seenVersion: Int32 = -1
    private let coeffs = UnsafeMutablePointer<Float>.allocate(capacity: eqBandCount * 5)     // b0 b1 b2 a1 a2
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: eqBandCount * 4)      // per band: L z1 z2, R z1 z2
    private let analysisCoeffs = UnsafeMutablePointer<Float>.allocate(capacity: eqBandCount * 5)
    private let analysisState = UnsafeMutablePointer<Float>.allocate(capacity: eqBandCount * 2)
    private let power = UnsafeMutablePointer<Float>.allocate(capacity: eqBandCount)
    private var preamp: Float = 1

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        gains.initialize(repeating: 0, count: eqBandCount); bandPower.initialize(repeating: 0, count: eqBandCount)
        enabled.initialize(to: 0); version.initialize(to: 0)
        coeffs.initialize(repeating: 0, count: eqBandCount * 5); state.initialize(repeating: 0, count: eqBandCount * 4)
        analysisCoeffs.initialize(repeating: 0, count: eqBandCount * 5); analysisState.initialize(repeating: 0, count: eqBandCount * 2)
        power.initialize(repeating: 0, count: eqBandCount)
        for band in 0..<eqBandCount {
            let w = 2 * Double.pi * eqFrequencies[band] / sampleRate, alpha = sin(w) / (2 * 1.4), a0 = 1 + alpha
            let c = analysisCoeffs + band * 5
            c[0] = Float(alpha / a0); c[1] = 0; c[2] = Float(-alpha / a0); c[3] = Float(-2 * cos(w) / a0); c[4] = Float((1 - alpha) / a0)
        }
    }
    deinit {
        [gains, bandPower, enabled, version].forEach { $0.deallocate() }
        [coeffs, state, analysisCoeffs, analysisState, power].forEach { $0.deallocate() }
    }

    // Main thread
    func set(gains newGains: [Double], enabled isOn: Bool) {
        for band in 0..<eqBandCount { atomicStore(gains + band, Float(newGains[band]).bitPattern) }
        atomicStore(enabled, isOn ? 1 : 0)
        _ = OSAtomicIncrement32Barrier(version)
    }
    func bandLevelsDB() -> [Double] { (0..<eqBandCount).map { 10 * log10(Double(max(Float(bitPattern: atomicLoad(bandPower + $0)), 1e-12))) } }

    private func updateCoefficients() {
        var maxBoost: Double = 0
        for band in 0..<eqBandCount {
            let gain = Double(Float(bitPattern: atomicLoad(gains + band)))
            maxBoost = max(maxBoost, gain)
            let A = pow(10, gain / 40), w = 2 * Double.pi * eqFrequencies[band] / sampleRate, cw = cos(w)
            var b0, b1, b2, a0, a1, a2: Double
            if band == 0 || band == eqBandCount - 1 {
                let alpha = sin(w) / 2 * sqrt(2.0), sa = 2 * sqrt(A) * alpha, sign: Double = band == 0 ? 1 : -1
                b0 = A * ((A + 1) - sign * (A - 1) * cw + sa)
                b1 = sign * 2 * A * ((A - 1) - sign * (A + 1) * cw)
                b2 = A * ((A + 1) - sign * (A - 1) * cw - sa)
                a0 = (A + 1) + sign * (A - 1) * cw + sa
                a1 = -sign * 2 * ((A - 1) + sign * (A + 1) * cw)
                a2 = (A + 1) + sign * (A - 1) * cw - sa
            } else {
                let alpha = sin(w) / (2 * 1.1)
                b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
                a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
            }
            let c = coeffs + band * 5
            c[0] = Float(b0 / a0); c[1] = Float(b1 / a0); c[2] = Float(b2 / a0); c[3] = Float(a1 / a0); c[4] = Float(a2 / a0)
        }
        // Pull the level down by half of the largest boost; the soft clipper catches the rest.
        preamp = Float(pow(10, -maxBoost * 0.5 / 20))
    }

    // Capture thread: analyze the untouched input, then EQ it in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let smoothing = Float(1 - exp(-Double(frames) / (sampleRate * 0.4)))
        for band in 0..<eqBandCount {
            let c = analysisCoeffs + band * 5, z = analysisState + band * 2
            var sum: Float = 0
            for frame in 0..<frames {
                let x = (samples[frame * 2] + samples[frame * 2 + 1]) * 0.5
                let y = c[0] * x + z[0]
                z[0] = c[1] * x - c[3] * y + z[1]; z[1] = c[2] * x - c[4] * y
                sum += y * y
            }
            power[band] += (sum / Float(frames) - power[band]) * smoothing
            atomicStore(bandPower + band, power[band].bitPattern)
        }

        guard atomicLoad(enabled) == 1 else { return }
        let v = Int32(bitPattern: atomicLoad(version))
        if v != seenVersion { seenVersion = v; updateCoefficients() }
        for band in 0..<eqBandCount {
            let c = coeffs + band * 5
            for channel in 0..<2 {
                let z = state + band * 4 + channel * 2
                for frame in 0..<frames {
                    let i = frame * 2 + channel, x = samples[i]
                    let y = c[0] * x + z[0]
                    z[0] = c[1] * x - c[3] * y + z[1]; z[1] = c[2] * x - c[4] * y
                    samples[i] = y
                }
            }
        }
        for i in 0..<frames * 2 {
            let x = samples[i] * preamp, m = abs(x)
            samples[i] = m <= 0.9 ? x : (x < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((m - 0.9) / 0.1))
        }
    }
}

// Configured and torn down on a background queue so slow devices (Bluetooth) can't hang the UI.
private final class Engine: @unchecked Sendable {
    let ring: AudioRing
    let eq: Equalizer
    let sampleRate: Double
    var inputUnit: AudioUnit?
    var outputUnit: AudioUnit?
    let captureABL = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    let captureStorage = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFramesPerSlice) * 2)

    init(channelMask: UInt32, sampleRate: Double, delayFrames: UInt32) {
        self.sampleRate = sampleRate
        self.ring = AudioRing(requestedDelay: delayFrames, channelMask: channelMask)
        self.eq = Equalizer(sampleRate: sampleRate)
        captureABL.initialize(to: AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: maxFramesPerSlice * 8, mData: captureStorage)))
    }
    deinit { stop(); captureABL.deinitialize(count: 1); captureABL.deallocate(); captureStorage.deallocate() }

    func configure(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID, outputChannelCount: UInt32) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw NSError(domain: "SyncDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "HAL Output audio component unavailable"]) }
        var inAU: AudioUnit?; try check(AudioComponentInstanceNew(component, &inAU), "create input unit")
        var outAU: AudioUnit?; try check(AudioComponentInstanceNew(component, &outAU), "create output unit")
        inputUnit = inAU; outputUnit = outAU
        guard let inputUnit = inputUnit, let outputUnit = outputUnit else { return }
        var one: UInt32 = 1
        try check(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &one, UInt32(MemoryLayout<UInt32>.size)), "enable input IO")
        var inDevice = inputDevice
        try check(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inDevice, UInt32(MemoryLayout<AudioDeviceID>.size)), "select input device")
        var inFormat = pcmFormat(channels: 2, sampleRate: sampleRate)
        try check(AudioUnitSetProperty(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &inFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set input client format")
        var inCallback = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")

        try check(AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputBus, &one, UInt32(MemoryLayout<UInt32>.size)), "enable output IO")
        var outDevice = outputDevice
        try check(AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outDevice, UInt32(MemoryLayout<AudioDeviceID>.size)), "select output device")
        var outFormat = pcmFormat(channels: outputChannelCount, sampleRate: sampleRate)
        try check(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, outputBus, &outFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set output client format")
        var outCallback = AURenderCallbackStruct(inputProc: outputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, outputBus, &outCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set output callback")
        var maxFrames = maxFramesPerSlice
        try check(AudioUnitSetProperty(inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)), "set input max frames")
        try check(AudioUnitSetProperty(outputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)), "set output max frames")
        try check(AudioUnitInitialize(inputUnit), "initialize input unit")
        try check(AudioUnitInitialize(outputUnit), "initialize output unit")
    }
    func start() throws { if let inputUnit { try check(AudioOutputUnitStart(inputUnit), "start input unit") }; if let outputUnit { try check(AudioOutputUnitStart(outputUnit), "start output unit") } }
    func stop() { if let u = inputUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u); inputUnit = nil }; if let u = outputUnit { AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u); outputUnit = nil } }
    func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32) -> OSStatus {
        guard frames <= maxFramesPerSlice, let inputUnit else { return noErr }
        // AudioUnitRender shrinks mDataByteSize to what it produced; restore it or later, larger requests fail.
        captureABL.pointee.mBuffers.mDataByteSize = frames * 8
        captureABL.pointee.mBuffers.mData = UnsafeMutableRawPointer(captureStorage)
        let status = AudioUnitRender(inputUnit, flags, time, inputBus, frames, captureABL)
        if status == noErr { eq.process(captureStorage, frames: Int(frames)); ring.write(captureStorage, frames: frames) } else { ring.bump(0) }
        return status
    }
    func render(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> OSStatus {
        let actual = ring.read(into: ioData, frames: frames)
        if actual < frames {
            for index in 0..<Int(ioData.pointee.mNumberBuffers) {
                let buffer = bufferAt(ioData, index)
                if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    let start = Int(actual) * Int(buffer.mNumberChannels)
                    data.advanced(by: start).initialize(repeating: 0, count: Int(frames - actual) * Int(buffer.mNumberChannels))
                }
            }
        }
        return noErr
    }
}

private let inputCallback: AURenderCallback = { refCon, flags, time, _, frames, _ in
    Unmanaged<Engine>.fromOpaque(refCon).takeUnretainedValue().capture(flags, time, frames)
}
private let outputCallback: AURenderCallback = { refCon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    return Unmanaged<Engine>.fromOpaque(refCon).takeUnretainedValue().render(ioData, frames: frames)
}

// MARK: Hardware output volume (per physical device inside the selected output)

private struct OutputVolume: Identifiable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
    var value: Double
}

/// Physical devices behind an output: an aggregate's sub-devices, or the device itself.
private func outputMemberUIDs(_ id: AudioDeviceID, uid: String) -> [String] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var list: Unmanaged<CFArray>?
    var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &list) == noErr, let uids = list?.takeUnretainedValue() as? [String], !uids.isEmpty else { return [uid] }
    return uids
}

private func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
}

/// The elements that carry volume: the main control if present, otherwise the individual channels.
private func volumeElements(_ id: AudioDeviceID) -> [UInt32] {
    var main = volumeAddress(kAudioObjectPropertyElementMain)
    if AudioObjectHasProperty(id, &main) { return [kAudioObjectPropertyElementMain] }
    return [1, 2].filter { var a = volumeAddress($0); return AudioObjectHasProperty(id, &a) }
}

private func hardwareVolume(_ id: AudioDeviceID) -> Double? {
    let values = volumeElements(id).compactMap { element -> Float? in
        var a = volumeAddress(element); var v = Float32(0); var size = UInt32(4)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }
    return values.isEmpty ? nil : Double(values.reduce(0, +) / Float(values.count))
}

private func setHardwareVolume(_ id: AudioDeviceID, _ value: Double) {
    for element in volumeElements(id) {
        var a = volumeAddress(element); var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(4), &v)
    }
}

/// Writes hardware volume off the main thread, keeping only the latest value per device.
/// A slider drag fires many changes and each Bluetooth write is a slow round trip.
private final class HardwareVolumeWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SyncDelay.volume", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [AudioDeviceID: Double] = [:]

    func set(_ id: AudioDeviceID, _ value: Double) {
        lock.lock(); let idle = pending.isEmpty; pending[id] = value; lock.unlock()
        guard idle else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let (device, latest) = pending.first else { lock.unlock(); return }
                pending[device] = nil
                lock.unlock()
                setHardwareVolume(device, latest)
            }
        }
    }
}

// MARK: Updates from GitHub Releases

/// This build is a fork with local changes, so it never installs the upstream binary over itself.
/// It only reports that upstream has a newer release; `update-from-upstream.sh` merges and rebuilds.
@MainActor
private final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "leviholliday/sync-delay"

    @Published var availableVersion: String?
    @Published var message: String?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func check(userInitiated: Bool = false) {
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else { throw URLError(.badServerResponse) }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Self.isNewer(version, than: currentVersion) {
                    availableVersion = version; message = nil
                } else {
                    availableVersion = nil
                    if userInitiated { message = "Sync Delay \(currentVersion) is the latest version." }
                }
            } catch {
                if userInitiated { message = "Couldn't check for updates: \(error.localizedDescription)" }
            }
        }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(Self.repo)/releases/latest")!)
    }
}

private struct DeviceChoice: Identifiable {
    let id: String
    let name: String
    let uid: String
    let inputChannels: UInt32
    let outputChannels: UInt32
}

/// Level meter values live in their own object so only the meter bars redraw 20 times a second,
/// not the whole window.
@MainActor
private final class MeterModel: ObservableObject {
    @Published private(set) var levels: (left: Float, right: Float) = (0, 0)

    func update(left: Float, right: Float) {
        guard abs(left - levels.left) > 0.003 || abs(right - levels.right) > 0.003 else { return }
        levels = (left, right)
    }
    func reset() { if levels.left != 0 || levels.right != 0 { levels = (0, 0) } }
}

@MainActor
private final class SyncDelayModel: ObservableObject {
    static let defaultDelay = 180.0
    static let maxDelay = 2_000.0

    @Published var devices: [DeviceChoice] = []
    @Published var inputUID: String { didSet { UserDefaults.standard.set(inputUID, forKey: "inputUID") } }
    @Published var outputUID: String { didSet { UserDefaults.standard.set(outputUID, forKey: "outputUID"); reloadOutputVolumes() } }
    @Published var delayMS: Double {
        didSet {
            let clamped = min(Self.maxDelay, max(0, delayMS.isFinite ? delayMS : 0))
            if clamped != delayMS { delayMS = clamped; return }
            UserDefaults.standard.set(delayMS, forKey: "delayMS"); applyDelay()
        }
    }
    @Published var delayedChannels: Set<Int> { didSet { UserDefaults.standard.set(delayedChannels.sorted().map(String.init).joined(separator: ","), forKey: "delayedChannels"); applyChannels() } }
    @Published var autoStart: Bool { didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") } }
    @Published var volume: Double { didSet { UserDefaults.standard.set(volume, forKey: "volume"); applyGain() } }
    @Published var muted = false { didSet { applyGain() } }
    @Published var outputVolumes: [OutputVolume] = []
    @Published var eqEnabled: Bool { didSet { UserDefaults.standard.set(eqEnabled, forKey: "eqEnabled"); applyEQ() } }
    @Published var eqPreset: String { didSet { UserDefaults.standard.set(eqPreset, forKey: "eqPreset"); if let p = EQPreset.all.first(where: { $0.name == eqPreset }), p.gains != eqGains { eqGains = p.gains } } }
    @Published var eqGains: [Double] { didSet { UserDefaults.standard.set(eqGains, forKey: "eqGains"); if !autoEQ { appliedGains = eqGains; liveGains = eqGains }; applyEQ() } }
    @Published var autoEQ: Bool { didSet { UserDefaults.standard.set(autoEQ, forKey: "autoEQ"); if !autoEQ { appliedGains = eqGains; liveGains = eqGains; applyEQ() } } }
    /// Gains shown on the sliders; equals eqGains unless Auto EQ is steering them. Published at ~2 Hz.
    @Published var liveGains: [Double] = Array(repeating: 0, count: eqBandCount)
    @Published var isRunning = false
    @Published var isConnecting = false
    @Published var hasError = false
    @Published var status = "Ready to connect"
    let meter = MeterModel()

    /// Gains actually sent to the EQ, updated every Auto EQ step.
    private var appliedGains: [Double] = Array(repeating: 0, count: eqBandCount)
    private var engine: Engine?
    /// Serial queue for Core Audio unit setup and teardown, which can block for seconds on Bluetooth devices.
    private let audioQueue = DispatchQueue(label: "SyncDelay.engine", qos: .userInitiated)
    private var engineGeneration = 0
    private let volumeWriter = HardwareVolumeWriter()
    private var tickTimer: Timer?
    private var tick = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var refreshTask: Task<Void, Never>?
    private var lastPositions: (written: UInt32, read: UInt32)?
    private var stalledSeconds = 0
    private var recentRestarts: [Date] = []

    var inputDevices: [DeviceChoice] { devices.filter { $0.inputChannels >= 2 } }
    var outputDevices: [DeviceChoice] { devices.filter { $0.outputChannels >= 2 } }
    /// Channels offered as delay targets: the selected output's channel count, or stereo until one is chosen.
    var outputChannelCount: Int { min(16, max(2, Int(devices.first(where: { $0.uid == outputUID })?.outputChannels ?? 2))) }

    init() {
        let defaults = UserDefaults.standard
        inputUID = defaults.string(forKey: "inputUID") ?? "BlackHole2ch_UID"
        outputUID = defaults.string(forKey: "outputUID") ?? ""
        delayMS = defaults.object(forKey: "delayMS") as? Double ?? Self.defaultDelay
        let saved = (defaults.string(forKey: "delayedChannels") ?? "0,1").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        delayedChannels = Set(saved.filter { $0 >= 0 && $0 < 32 })
        autoStart = defaults.bool(forKey: "autoStart")
        volume = defaults.object(forKey: "volume") as? Double ?? 1
        eqEnabled = defaults.bool(forKey: "eqEnabled")
        eqPreset = defaults.string(forKey: "eqPreset") ?? "Flat"
        let savedGains = defaults.array(forKey: "eqGains") as? [Double]
        eqGains = savedGains?.count == eqBandCount ? savedGains! : Array(repeating: 0, count: eqBandCount)
        autoEQ = defaults.bool(forKey: "autoEQ")
        liveGains = eqGains
        appliedGains = eqGains
        refreshDevices()
        watchDevices()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in guard let self else { return }; Task { @MainActor in self.reloadOutputVolumes() } }
        // Audio units often stop delivering audio after sleep; reconnect once the hardware is back.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.isRunning else { return }
                self.startEngine(note: "reconnected after sleep")
            }
        }
        // A second copy would play everything twice; it hands off to the running one and quits.
        if autoStart, !outputUID.isEmpty, alreadyRunningCopy == nil { start() }
    }
    deinit { engine?.stop(); tickTimer?.invalidate() }

    private func watchDevices() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in guard let self else { return }; Task { @MainActor in self.scheduleRefresh() } }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    /// Device changes arrive in bursts (a Bluetooth connect or aggregate rebuild fires several); refresh once they settle.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshDevices()
        }
    }

    func reloadOutputVolumes() {
        guard !outputUID.isEmpty, let all = try? allDevices() else { outputVolumes = []; return }
        // One pass over the device list instead of a full re-scan per aggregate member.
        var byUID: [String: (AudioDeviceID, String)] = [:]
        for id in all {
            if let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) { byUID[uid] = (id, stringProperty(id, kAudioObjectPropertyName) ?? "Unknown") }
        }
        guard let (outputID, _) = byUID[outputUID] else { outputVolumes = []; return }
        outputVolumes = outputMemberUIDs(outputID, uid: outputUID).compactMap { uid in
            guard let (id, name) = byUID[uid], let value = hardwareVolume(id) else { return nil }
            return OutputVolume(id: uid, name: name, deviceID: id, value: value)
        }
    }

    func setOutputVolume(_ uid: String, _ value: Double) {
        guard let index = outputVolumes.firstIndex(where: { $0.id == uid }) else { return }
        volumeWriter.set(outputVolumes[index].deviceID, value)
        outputVolumes[index].value = value
    }

    func refreshDevices() {
        do {
            devices = try allDevices().compactMap { id in
                guard let name = stringProperty(id, kAudioObjectPropertyName), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
                return DeviceChoice(id: uid, name: name, uid: uid,
                    inputChannels: (try? channelCount(id, scope: kAudioDevicePropertyScopeInput)) ?? 0,
                    outputChannels: (try? channelCount(id, scope: kAudioDevicePropertyScopeOutput)) ?? 0)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !devices.contains(where: { $0.uid == inputUID }), let blackHole = devices.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") }) { inputUID = blackHole.uid }
            if isRunning || isConnecting {
                if !devices.contains(where: { $0.uid == inputUID }) || !devices.contains(where: { $0.uid == outputUID }) {
                    stop(); hasError = true; status = "A selected device disconnected. Reconnect it and press Start Sync."
                }
            } else if !hasError || status.hasPrefix("A selected device") { hasError = false; status = "Ready to connect" }
            reloadOutputVolumes()
        } catch { hasError = true; status = error.localizedDescription }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            status = "Allow microphone access to receive audio from BlackHole…"
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted {
                        self.startEngine()
                    } else {
                        self.hasError = true
                        self.status = "Microphone access is required. Enable Sync Delay in System Settings → Privacy & Security → Microphone."
                    }
                }
            }
        case .denied, .restricted:
            hasError = true
            status = "Microphone access is required. Enable Sync Delay in System Settings → Privacy & Security → Microphone."
        @unknown default:
            hasError = true
            status = "Unable to determine microphone permission."
        }
    }

    private var channelMask: UInt32 { delayedChannels.filter { $0 < 32 }.reduce(0) { $0 | (1 << UInt32($1)) } }

    /// Stops the current engine on the audio queue and invalidates any start still in flight.
    private func tearDownEngine() {
        engineGeneration += 1
        if let old = engine { engine = nil; audioQueue.async { old.stop() } }
        isRunning = false; isConnecting = false
        stopTicks()
    }

    private func startEngine(note: String? = nil) {
        tearDownEngine()
        do {
            guard !inputUID.isEmpty, !outputUID.isEmpty else { throw NSError(domain: "SyncDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select both an input device and an Aggregate Device."]) }
            let (inputID, inputName) = try findDevice(inputUID)
            let (outputID, outputName) = try findDevice(outputUID)
            let inputs = try channelCount(inputID, scope: kAudioDevicePropertyScopeInput)
            guard inputs >= 2 else { throw NSError(domain: "SyncDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected input is not stereo."]) }
            let outputs = try channelCount(outputID, scope: kAudioDevicePropertyScopeOutput)
            guard outputs >= 2 else { throw NSError(domain: "SyncDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected output has fewer than two channels."]) }
            guard !delayedChannels.isEmpty else { throw NSError(domain: "SyncDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose at least one output channel to delay."]) }
            guard delayedChannels.allSatisfy({ $0 < Int(outputs) }) else {
                throw NSError(domain: "SyncDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Delayed channels must be within the output's \(outputs) channels (0 through \(outputs - 1))."])
            }
            let sampleRate = 48_000.0
            let engine = Engine(channelMask: channelMask, sampleRate: sampleRate, delayFrames: UInt32((delayMS * sampleRate / 1000).rounded()))
            engine.ring.setGain(gainValue)
            engine.eq.set(gains: appliedGains, enabled: eqEnabled)
            let generation = engineGeneration
            isConnecting = true
            hasError = false
            status = "Connecting · \(inputName) → \(outputName)…"
            audioQueue.async { [weak self] in
                let failure: Error?
                do {
                    try engine.configure(inputDevice: inputID, outputDevice: outputID, outputChannelCount: outputs)
                    try engine.start()
                    failure = nil
                } catch { engine.stop(); failure = error }
                guard let self else { engine.stop(); return }
                Task { @MainActor in
                    guard generation == self.engineGeneration else {
                        // Stopped or restarted while this start was in flight.
                        self.audioQueue.async { engine.stop() }
                        return
                    }
                    self.isConnecting = false
                    if let failure { self.hasError = true; self.status = failure.localizedDescription; return }
                    self.engine = engine
                    self.isRunning = true
                    self.status = "In sync · \(inputName) → \(outputName) · \(outputs) channels" + (note.map { " · \($0)" } ?? "")
                    self.startTicks()
                }
            }
        } catch { hasError = true; status = error.localizedDescription }
    }

    func stop() { tearDownEngine(); hasError = false; status = "Stopped · your settings are saved" }
    func adjustDelay(_ amount: Double) { delayMS += amount }
    func resetDelay() { delayMS = Self.defaultDelay }
    func toggleChannel(_ channel: Int) {
        if delayedChannels.contains(channel) { delayedChannels.remove(channel) } else { delayedChannels.insert(channel) }
    }
    private func applyDelay() { guard let engine else { return }; engine.ring.setDelay(UInt32((delayMS * engine.sampleRate / 1000).rounded())) }
    private var gainValue: Float { muted ? 0 : Float(volume * volume) } // squared for a natural-feeling taper
    private func applyGain() { engine?.ring.setGain(gainValue) }
    private func applyEQ() { engine?.eq.set(gains: appliedGains, enabled: eqEnabled) }
    func setBand(_ band: Int, _ gain: Double) {
        var gains = eqGains; gains[band] = gain; eqGains = gains
        if EQPreset.all.first(where: { $0.name == eqPreset })?.gains != gains { eqPreset = "Custom" }
    }

    /// Typical long-term music balance per band (dB, relative) as measured by the analyzer.
    private static let referenceBalance: [Double] = [4, 3, 1, 0, -3, -7]
    private var autoSteps = 0
    /// Nudges each band so the song's measured balance moves toward the reference, then layers the preset on top.
    private func stepAutoEQ() {
        guard autoEQ, eqEnabled, let eq = engine?.eq else { return }
        let levels = eq.bandLevelsDB()
        let mean = levels.reduce(0, +) / Double(eqBandCount)
        guard mean > -70 else { return } // silence or a quiet gap: hold the current curve
        var correction = (0..<eqBandCount).map { min(6, max(-6, (Self.referenceBalance[$0] - (levels[$0] - mean)) * 0.5)) }
        let offset = correction.reduce(0, +) / Double(eqBandCount)
        correction = correction.map { $0 - offset }
        appliedGains = (0..<eqBandCount).map { band in
            let target = min(12, max(-12, eqGains[band] + correction[band]))
            return appliedGains[band] + (target - appliedGains[band]) * 0.04 // ~2.5 s glide
        }
        applyEQ()
        // The sliders only need to follow along; publishing every step redraws the whole window.
        autoSteps += 1
        if autoSteps % 5 == 0 { liveGains = appliedGains }
    }

    private func applyChannels() { engine?.ring.setChannelMask(channelMask) }

    /// True when a Sync Delay window is on screen and not fully covered. The menu bar item doesn't count.
    private var windowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && $0.occlusionState.contains(.visible) }
    }

    /// One 20 Hz timer while running: meters (only when visible), Auto EQ at 10 Hz, and a 1 Hz stall watchdog.
    private func startTicks() {
        tickTimer?.invalidate()
        tick = 0; lastPositions = nil; stalledSeconds = 0
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.onTick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }
    private func stopTicks() { tickTimer?.invalidate(); tickTimer = nil; meter.reset() }

    private func onTick() {
        guard let ring = engine?.ring else { return }
        tick += 1
        if windowVisible {
            func shape(_ peak: Float, _ previous: Float) -> Float {
                let db = 20 * log10(max(peak, 0.000_001))
                return max(min(1, max(0, (db + 60) / 60)), previous * 0.8)
            }
            let previous = meter.levels
            meter.update(left: shape(ring.peak(0), previous.left), right: shape(ring.peak(1), previous.right))
        } else {
            meter.reset()
        }
        if tick % 2 == 0 { stepAutoEQ() }
        if tick % 20 == 0 { checkForStall(ring) }
    }

    /// If either side of the ring stops moving for 3 seconds the devices stopped delivering audio
    /// (a Bluetooth speaker dropped out of the aggregate, a sample-rate switch, etc.). Reconnect,
    /// but give up after 3 tries in a minute so a missing device doesn't cause a restart loop.
    private func checkForStall(_ ring: AudioRing) {
        let now = ring.positions()
        defer { lastPositions = now }
        if ProcessInfo.processInfo.environment["SYNCDELAY_DEBUG"] != nil {
            let st = ring.stats; NSLog("SD stats err=%d under=%d drop=%d over=%d", st[0], st[1], st[2], st[3])
        }
        guard let last = lastPositions else { return }
        stalledSeconds = (last.written == now.written || last.read == now.read) ? stalledSeconds + 1 : 0
        guard stalledSeconds >= 3 else { return }
        recentRestarts = recentRestarts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        if recentRestarts.count > 3 {
            stop(); hasError = true
            status = "Audio stopped flowing and reconnecting didn't help. Check your speakers, then press Start."
        } else {
            NSLog("Sync Delay: audio stalled, reconnecting")
            startEngine(note: "reconnected after audio stalled")
        }
    }
}

private struct LevelBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.985 ? Color.red : Color.green).frame(width: max(3, geo.size.width * CGFloat(level)))
                    .opacity(level > 0.01 ? 1 : 0)
            }
        }
        .frame(height: 5)
    }
}

private struct EQBandSlider: View {
    let label: String
    @Binding var gain: Double
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 6) {
            Text(gain.rounded() == 0 ? "0" : String(format: "%+.0f", gain.rounded()))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            GeometryReader { geo in
                let h = geo.size.height, y = CGFloat((12 - gain) / 24) * h, mid = h / 2
                ZStack(alignment: .top) {
                    Capsule().fill(.quaternary).frame(width: 4, height: h)
                    Rectangle().fill(.tertiary).frame(width: 12, height: 1).offset(y: mid)
                    Capsule().fill(isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 4, height: abs(y - mid)).offset(y: min(y, mid))
                    Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .frame(width: 16, height: 16).offset(y: y - 8)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in gain = min(12, max(-12, 12 - Double(g.location.y / h) * 24)) })
                .onTapGesture(count: 2) { gain = 0 }
            }
            .frame(height: 130)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ClearInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.makeFirstResponder(nil) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The two level bars watch the meter on their own, so meter updates don't redraw the rest of the window.
private struct MeterRow: View {
    @ObservedObject var meter: MeterModel
    var body: some View {
        LabeledContent("Level") {
            VStack(spacing: 3) { LevelBar(level: meter.levels.left); LevelBar(level: meter.levels.right) }.frame(width: 160)
        }
    }
}

/// Menu bar controls, so sync keeps running and stays reachable with the window closed.
private struct MenuBarContent: View {
    @ObservedObject var model: SyncDelayModel
    @Environment(\.openWindow) private var openWindow

    private var summary: String {
        if model.isRunning { return model.muted ? "In sync · muted" : "In sync" }
        if model.isConnecting { return "Connecting…" }
        return model.hasError ? "Not running · open the window for details" : "Stopped"
    }

    private func showWindow() { showMainWindow(fallback: openWindow) }

    var body: some View {
        Text(summary)
        if model.isRunning || model.isConnecting {
            Button("Stop Sync") { model.stop() }
        } else {
            Button("Start Sync") { model.start() }
        }
        Divider()
        Menu("Delay: \(Int(model.delayMS.rounded())) ms") {
            Button("+5 ms") { model.adjustDelay(5) }
            Button("+1 ms") { model.adjustDelay(1) }
            Button("−1 ms") { model.adjustDelay(-1) }
            Button("−5 ms") { model.adjustDelay(-5) }
            Divider()
            Button("Reset to \(Int(SyncDelayModel.defaultDelay)) ms") { model.resetDelay() }
        }
        Toggle("Mute", isOn: $model.muted)
        Divider()
        Button("Open Sync Delay") { showWindow() }
        Button("Check for Updates…") { Updater.shared.check(userInitiated: true); showWindow() }
        Divider()
        Button("Quit Sync Delay") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

private let mainWindowID = "main"

/// Brings the main window back. SwiftUI keeps the closed window object (id "main") alive but
/// `openWindow` doesn't re-show it, so order the existing window front and only fall back to
/// `openWindow` if it's really gone.
@MainActor
private func showMainWindow(fallback: OpenWindowAction? = nil) {
    NSApp.setActivationPolicy(.regular)
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == mainWindowID }) {
        window.makeKeyAndOrderFront(nil)
    } else {
        fallback?(id: mainWindowID)
    }
    NSApp.activate(ignoringOtherApps: true)
}

/// Another copy of Sync Delay (same bundle ID) that was already running when this one launched.
private let alreadyRunningCopy: NSRunningApplication? = NSRunningApplication
    .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.syncdelay.app")
    .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

private struct ContentView: View {
    @ObservedObject var model: SyncDelayModel
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
        Form {
            Section("Devices") {
                Picker("Input", selection: $model.inputUID) {
                    Text("None").tag("")
                    ForEach(model.inputDevices) { Text($0.name).tag($0.uid) }
                }
                Picker("Output", selection: $model.outputUID) {
                    Text("None").tag("")
                    ForEach(model.outputDevices) { Text($0.name).tag($0.uid) }
                }
            }

            Section("Delay") {
                LabeledContent("Amount") {
                    HStack(spacing: 4) {
                        TextField("", value: $model.delayMS, format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).frame(width: 64)
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
                Slider(value: $model.delayMS, in: 0...1_000, step: 1)
                HStack {
                    Button("−5") { model.adjustDelay(-5) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    Button("−1") { model.adjustDelay(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("+1") { model.adjustDelay(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
                    Button("+5") { model.adjustDelay(5) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    Spacer()
                    Button("Reset") { model.resetDelay() }
                }
                LabeledContent("Delayed channels") {
                    HStack(spacing: 4) {
                        ForEach(0..<model.outputChannelCount, id: \.self) { channel in
                            Toggle("\(channel)", isOn: Binding(get: { model.delayedChannels.contains(channel) }, set: { _ in model.toggleChannel(channel) }))
                                .toggleStyle(.button)
                        }
                    }
                }
            }

            Section("Volume") {
                HStack(spacing: 8) {
                    Button { model.muted.toggle() } label: {
                        Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : (model.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"))
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .help("Mute (⇧⌘M)")
                    Slider(value: $model.volume, in: 0...1)
                        .onReceive(model.$volume.dropFirst()) { _ in model.muted = false }
                    Text("\(Int((model.volume * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                if model.isRunning {
                    MeterRow(meter: model.meter)
                }
            }

            if !model.outputVolumes.isEmpty {
                Section("Output levels") {
                    ForEach(model.outputVolumes) { output in
                        HStack(spacing: 10) {
                            Text(output.name).lineLimit(1).truncationMode(.tail).frame(width: 175, alignment: .leading).help(output.name)
                            Slider(value: Binding(get: { output.value }, set: { model.setOutputVolume(output.id, $0) }), in: 0...1)
                            Text("\(Int((output.value * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(model.hasError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if model.isRunning || model.isConnecting {
                        Button("Stop") { model.stop() }.keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button("Start") { model.start() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    }
                }
                if let version = updater.availableVersion {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Sync Delay \(version) is available upstream", systemImage: "arrow.down.circle")
                                .font(.callout)
                            Text("Merge it into your build with update-from-upstream.sh.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("View Release") { updater.openReleasePage() }
                    }
                }
                if let message = updater.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("Start on launch", isOn: $model.autoStart)
                    Spacer()
                    Button("Refresh Devices") { model.refreshDevices() }.buttonStyle(.link)
                }
                .font(.callout)
                Text("Closing this window keeps sync running. Use the menu bar icon to reopen it or quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)

        Form {
            Section("Equalizer") {
                Toggle("Equalizer", isOn: $model.eqEnabled)
                Picker("Preset", selection: $model.eqPreset) {
                    ForEach(EQPreset.all, id: \.name) { Text($0.name).tag($0.name) }
                    if model.eqPreset == "Custom" { Divider(); Text("Custom").tag("Custom") }
                }
                .disabled(!model.eqEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Auto EQ", isOn: $model.autoEQ)
                    Text("Adjusts during each song, steering toward the preset's sound.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!model.eqEnabled)
                HStack(spacing: 0) {
                    ForEach(0..<eqBandCount, id: \.self) { band in
                        EQBandSlider(
                            label: eqFrequencies[band] >= 1_000 ? "\(Int(eqFrequencies[band] / 1_000))k" : "\(Int(eqFrequencies[band]))",
                            gain: Binding(get: { model.liveGains[band] }, set: { model.setBand(band, $0) }))
                    }
                }
                .padding(.vertical, 4)
                .disabled(!model.eqEnabled || model.autoEQ)
                .opacity(model.eqEnabled ? 1 : 0.5)
                HStack {
                    if model.autoEQ && model.eqEnabled {
                        Text(model.isRunning ? "Auto EQ is adjusting live" : "Auto EQ starts when sync is running")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset to Preset") {
                        if let p = EQPreset.all.first(where: { $0.name == model.eqPreset }) { model.eqGains = p.gains } else { model.eqPreset = "Flat" }
                    }
                    .disabled(!model.eqEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        }
        .frame(height: 624 + (model.outputVolumes.isEmpty ? 0 : 70 + CGFloat(model.outputVolumes.count) * 34) + (updater.availableVersion == nil ? 0 : 60) + (updater.message == nil ? 0 : 24))
        .background(ClearInitialFocus())
        .onAppear { NSApp.setActivationPolicy(.regular) }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep running (and syncing) with no window open; the menu bar item reopens it or quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Opening the app again (Finder, Spotlight, Dock) while it runs with no window shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Task { @MainActor in showMainWindow() } }
        return false
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let other = alreadyRunningCopy else { return }
        // Ask the running copy to show its window (sends it a reopen event), then quit this one.
        if let url = other.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            NSApp.terminate(nil)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "png"), let icon = NSImage(contentsOfFile: path) {
            NSApplication.shared.applicationIconImage = icon
        }
        // Drop the Dock icon while the window is closed; the app lives in the menu bar until it reopens.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
            if !othersOpen { NSApp.setActivationPolicy(.accessory) }
        }
        Task { @MainActor in Updater.shared.check() }
    }
}

@main
private struct SyncDelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = SyncDelayModel()

    var body: some Scene {
        Window("Sync Delay", id: mainWindowID) { ContentView(model: model) }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
                }
            }
            .windowResizability(.contentSize)
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.isRunning ? "speaker.wave.2.circle.fill" : "speaker.slash.circle")
        }
    }
}
