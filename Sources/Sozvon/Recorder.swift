// Call audio capture into two m4a (AAC) tracks: the microphone through ScreenCaptureKit, system audio
// through a Core Audio process tap (ScreenCaptureKit only when the tap can't start).

import AVFoundation
import os
import ScreenCaptureKit
import SozvonCore

// MARK: - Single-track writer that fills gaps with silence

/// The track is written on the capture queue (AudioSink.queue): all its state is touched only there.
/// Only a level snapshot under a lock goes out to the main thread.
final class TrackWriter: @unchecked Sendable {
    struct Meter: Sendable {
        /// Latest signal level on the meter scale (Levels.meter).
        var level: Float = 0
        var lastBufferAt: Date?
        /// The latest packet was digital silence (Levels.isDigitalSilence): a dead device, not a quiet room.
        var zero = false
        /// A packet with signal (not digital silence) arrived since the start: sticky, for the setup check.
        var heard = false
        /// For the panel's waveform only (Levels.display).
        var display: Float = 0
    }

    let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private(set) var firstPTS: Double?
    /// Wall clock time of the first written packet (for the "important" marks).
    private(set) var firstAt: Date?
    private var framesWritten: AVAudioFramePosition = 0
    private var loggedFormat: (Double, UInt32, UInt32, UInt32)?
    /// Don't write: the track file already existed on disk, it couldn't be opened (logged once), or the
    /// writer discards its audio (`discard`).
    private var refused = false
    /// This writer created the track file (so `AudioSink.discard()` may remove it).
    private var created = false
    private let meterLock = OSAllocatedUnfairLock(initialState: Meter())

    /// `discard`: keep the meter, write nothing (the permission check's short tap).
    init(url: URL, discard: Bool = false) {
        self.url = url
        refused = discard
    }

    /// Level and time of the last packet: readable from any thread.
    var meter: Meter { meterLock.withLock { $0 } }

    var seconds: Double {
        guard let format else { return 0 }
        return Double(framesWritten) / format.sampleRate
    }

    func append(_ sb: CMSampleBuffer) {
        guard sb.isValid, let fd = CMSampleBufferGetFormatDescription(sb),
              CMFormatDescriptionGetMediaType(fd) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
        else { return }
        logFormatOnce(asbd)
        // Linear PCM only, otherwise AVAudioPCMBuffer crashes (SIGSEGV).
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let rawFmt = TrackWriter.format(for: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let rawBuf = AVAudioPCMBuffer(pcmFormat: rawFmt, frameCapacity: frames) else { return }
        rawBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: rawBuf.mutableAudioBufferList) == noErr else { return }
        // A microphone array (the MacBook Pro mic gives 3 channels on macOS 26): AAC can't take a discrete
        // 3-channel layout, so the track would stay empty. Keep the first capsule, mono.
        let inBuf: AVAudioPCMBuffer
        if rawFmt.channelCount > 2 {
            guard let mono = Self.firstChannel(rawBuf) else { return }
            inBuf = mono
        } else {
            inBuf = rawBuf
        }
        let inFmt = inBuf.format
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let raw = Self.rawRMS(inBuf)
        meterLock.withLock {
            let zero = Levels.isDigitalSilence(raw)
            $0 = Meter(level: Levels.meter(raw), lastBufferAt: Date(), zero: zero, heard: $0.heard || !zero,
                       display: Levels.display(raw))
        }
        logLevel(raw)

        if file == nil {
            // A new recording always gets its own empty folder: never overwrite someone else's track.
            guard !refused else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                refused = true
                RecorderLog.write("\(url.lastPathComponent) already exists, not overwriting")
                return
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: inFmt.sampleRate,
                AVNumberOfChannelsKey: inFmt.channelCount,
                AVEncoderBitRateKey: 64000 * Int(inFmt.channelCount),
            ]
            do {
                let f = try AVAudioFile(forWriting: url, settings: settings,
                                        commonFormat: inFmt.commonFormat, interleaved: inFmt.isInterleaved)
                file = f
                created = true
                format = f.processingFormat
                firstPTS = pts
                firstAt = Date()
            } catch {
                // Not again on every packet: the track stays empty for this recording.
                refused = true
                RecorderLog.write("cannot open \(url.lastPathComponent): \(error), not writing this track")
                return
            }
        }
        guard let file, let format, let firstPTS else { return }
        // While a source is captured again, the old and the new stream overlap for a moment:
        // a packet from before the end of what is written is a duplicate.
        if pts < firstPTS + Double(framesWritten) / format.sampleRate - GapFiller.threshold { return }

        // The format may change on the fly (AirPods connected): convert back to the original.
        var buf = inBuf
        if !inFmt.isEqual(format) {
            if converter.map({ !$0.inputFormat.isEqual(inFmt) }) ?? true {
                converter = AVAudioConverter(from: inFmt, to: format)
            }
            guard let converter,
                  let out = AVAudioPCMBuffer(pcmFormat: format,
                      frameCapacity: AVAudioFrameCount(Double(frames) * format.sampleRate / inFmt.sampleRate) + 1024)
            else { return }
            let input = OneShotInput(inBuf)
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                guard let b = input.take() else { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData
                return b
            }
            if err != nil || out.frameLength == 0 { return }
            buf = out
        }

        // If the stream was interrupted (system silence), pad with zeros so the timeline doesn't drift.
        let silence = GapFiller.silenceFrames(firstPTS: firstPTS, framesWritten: Int64(framesWritten),
                                              sampleRate: format.sampleRate, pts: pts)
        for n in GapFiller.chunks(silence, maxChunk: Int64(format.sampleRate)) {
            guard let sil = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            sil.frameLength = AVAudioFrameCount(n)
            for ab in UnsafeMutableAudioBufferListPointer(sil.mutableAudioBufferList) {
                if let p = ab.mData { memset(p, 0, Int(ab.mDataByteSize)) }
            }
            try? file.write(from: sil)
            framesWritten += AVAudioFramePosition(n)
        }
        do {
            try file.write(from: buf)
            framesWritten += AVAudioFramePosition(buf.frameLength)
        } catch {
            RecorderLog.write("\(url.lastPathComponent): write error \(error)")
        }
    }

    /// Input format. AVAudioFormat(cmAudioFormatDescription:) returns nil on some microphones (headsets in
    /// call mode, multichannel devices without a layout) and crashes the app, so we build the format
    /// from the ASBD ourselves, with an explicit layout for more than 2 channels.
    static func format(for asbd: AudioStreamBasicDescription) -> AVAudioFormat? {
        var d = asbd
        if d.mChannelsPerFrame <= 2, let f = AVAudioFormat(streamDescription: &d) { return f }
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(d.mChannelsPerFrame)
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(streamDescription: &d, channelLayout: layout)
    }

    private var levelSum: Double = 0
    private var levelCount = 0
    private var levelSince = Date()

    /// Every 30 s, the track's average level in dB, to check later what the meter saw.
    private func logLevel(_ raw: Float) {
        levelSum += Double(raw * raw)
        levelCount += 1
        guard Date().timeIntervalSince(levelSince) >= 30 else { return }
        let db = 10 * log10(max(levelSum / Double(max(levelCount, 1)), 1e-12))
        RecorderLog.write("\(url.lastPathComponent): level \(Int(db.rounded())) dB over \(levelCount) packets")
        levelSum = 0
        levelCount = 0
        levelSince = Date()
    }

    /// Log the track format (on the first packet and on change) to help debug microphone issues.
    private func logFormatOnce(_ a: AudioStreamBasicDescription) {
        let key = (a.mSampleRate, a.mFormatID, a.mChannelsPerFrame, a.mFormatFlags)
        if let l = loggedFormat, l == key { return }
        loggedFormat = key
        let id = String(bytes: withUnsafeBytes(of: a.mFormatID.bigEndian) { Array($0) }, encoding: .ascii) ?? "\(a.mFormatID)"
        RecorderLog.write("\(url.lastPathComponent): \(id) \(a.mSampleRate) Hz, \(a.mChannelsPerFrame) ch, "
            + "\(a.mBitsPerChannel) bit, flags \(a.mFormatFlags), bytes/frame \(a.mBytesPerFrame)")
    }

    /// The first channel of a multichannel buffer as Float32 mono (interleaved or not, Float32, Int16 or Int32).
    static func firstChannel(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let n = Int(b.frameLength), ch = Int(b.format.channelCount), step = b.format.isInterleaved ? ch : 1
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1,
                                      interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: b.frameLength),
              let o = out.floatChannelData?[0] else { return nil }
        out.frameLength = b.frameLength
        if let f = b.floatChannelData?[0] {
            for i in 0..<n { o[i] = f[i * step] }
        } else if let q = b.int16ChannelData?[0] {
            for i in 0..<n { o[i] = Float(q[i * step]) / 32768 }
        } else if let q = b.int32ChannelData?[0] {
            for i in 0..<n { o[i] = Float(q[i * step]) / 2147483648 }
        } else {
            return nil
        }
        return out
    }

    /// Plain RMS of the first channel, 0...1 (an Int32 track would otherwise read as digital silence).
    static func rawRMS(_ buf: AVAudioPCMBuffer) -> Float {
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let f = buf.floatChannelData?[0] {
            for i in 0..<n { sum += f[i] * f[i] }
        } else if let s16 = buf.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(s16[i]) / 32768; sum += v * v }
        } else if let s32 = buf.int32ChannelData?[0] {
            for i in 0..<n { let v = Float(s32[i]) / 2147483648; sum += v * v }
        } else {
            return 0
        }
        return sqrt(sum / Float(n))
    }

    func close() {
        file?.close()
        file = nil
    }

    /// Close and remove the file this writer created, and write nothing more (a start that failed).
    func remove() {
        close()
        refused = true
        if created { try? FileManager.default.removeItem(at: url) }
        created = false
    }
}

/// A single input buffer for AVAudioConverter, handed out once. The converter calls the block
/// synchronously inside convert, on the same queue, so no lock is needed.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ b: AVAudioPCMBuffer) { buffer = b }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - Capture packet sink

/// Receives packets on its own queue and routes them to tracks. Tracks are fixed for the whole recording,
/// so the sink is safe to hand to ScreenCaptureKit.
final class AudioSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "sozvon.audio")
    let system: TrackWriter
    let mic: TrackWriter

    /// `discard`: levels only, no files (the system audio permission check).
    init(dir: URL, discard: Bool = false) {
        system = TrackWriter(url: dir.appendingPathComponent("system.m4a"), discard: discard)
        mic = TrackWriter(url: dir.appendingPathComponent("mic.m4a"), discard: discard)
    }

    /// A sink that writes nothing anywhere.
    static func discarding() -> AudioSink {
        AudioSink(dir: FileManager.default.temporaryDirectory, discard: true)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: system.append(sb)
        case .microphone: mic.append(sb)
        default: break
        }
    }

    /// Close the files (after capture stops) and return the track start offsets, plus the same starts
    /// as wall clock times (seconds since 1970) for the marks.
    func finish() -> (audio: AudioTimes, wall: AudioTimes) {
        queue.sync {
            system.close()
            mic.close()
            return (AudioTimes(micStart: mic.firstPTS, systemStart: system.firstPTS,
                               micSeconds: mic.seconds, systemSeconds: system.seconds),
                    AudioTimes(micStart: mic.firstAt?.timeIntervalSince1970,
                               systemStart: system.firstAt?.timeIntervalSince1970))
        }
    }

    /// Close and remove the track files written so far (after capture stops): a start that failed leaves
    /// a folder CallFolder.discardIfUnused can remove. Packets already queued run first (a serial queue).
    func discard() {
        queue.sync {
            system.remove()
            mic.remove()
        }
    }
}

// MARK: - recorder.log

/// Capture events and levels in Logs/recorder.log, to check later what a recording went through.
enum RecorderLog {
    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let f = Paths.logs.appendingPathComponent("recorder.log")
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - System audio through a Core Audio process tap

/// Everything the Mac plays, through a Core Audio process tap (macOS 14.2+), minus Sozvon's own sounds.
/// Unlike ScreenCaptureKit it also hears audio played by system daemons: a FaceTime call is played by
/// avconferenced, which ScreenCaptureKit leaves out. Packets go to the sink as CMSampleBuffers with host
/// time stamps, the clock ScreenCaptureKit uses for the microphone, so the tracks stay in sync.
final class SystemTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    init(sink: AudioSink) throws {
        let me = Self.processObject(pid: getpid())
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me.map { [$0] } ?? [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(desc, &tapID), "tap")
        do {
            var asbd = AudioStreamBasicDescription()
            var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "format")
            // The aggregate device runs on the clock of the current output device.
            let output = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Sozvon system audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "aggregate")
            // The tap's stream comes last in the aggregate's input, after the output device's own inputs
            // (a USB headset or AirPods in a call have a microphone on the same device), and in the
            // aggregate's sample rate: its format is what the IO block really gets.
            let inputs = Self.inputBufferChannels(aggregateID)
            if let stream = Self.lastInputStreamFormat(aggregateID), stream.mFormatID == kAudioFormatLinearPCM,
               stream.mBytesPerFrame > 0, stream.mSampleRate > 0 {
                asbd = stream
            }
            let tapBuffers = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(asbd.mChannelsPerFrame) : 1
            RecorderLog.write("system audio: process tap on \(output), \(asbd.mSampleRate) Hz \(asbd.mChannelsPerFrame) ch, "
                              + "input buffers \(inputs) (the tap is the last \(tapBuffers))")
            var format: CMAudioFormatDescription?
            try Self.check(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                          magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                          formatDescriptionOut: &format), "description")
            guard let format else { throw Failure(step: "description", status: -1) }
            let streamFormat = asbd
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, inputTime, _, _ in
                guard let sb = Self.sampleBuffer(input, tapBuffers: tapBuffers, time: inputTime.pointee,
                                                 asbd: streamFormat, format: format) else { return }
                let packet = Packet(sb)
                sink.queue.async { sink.system.append(packet.buffer) }
            }, "io")
            try Self.check(AudioDeviceStart(aggregateID, procID), "start")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    /// A finished sample buffer handed from the IO thread to the capture queue: nothing mutates it after.
    private struct Packet: @unchecked Sendable {
        let buffer: CMSampleBuffer
        init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }

    /// The Core Audio object of a process, to keep Sozvon's own chimes and player out of the tap.
    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// The default output (where call audio plays), the device whose change Recorder watches.
    /// Not the "system output" of alerts, which may be another device.
    private static func defaultOutputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "output")
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "output uid")
        guard let uid else { throw Failure(step: "output uid", status: -1) }
        return uid.takeRetainedValue() as String
    }

    /// Channels of each buffer the aggregate's IO block gets as input (for recorder.log).
    private static func inputBufferChannels(_ device: AudioObjectID) -> [Int] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    /// The format of the aggregate's last input stream: the tap.
    private static func lastInputStreamFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr, let last = streams.last else { return nil }
        var f = AudioStreamBasicDescription()
        var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(last, &addr, 0, nil, &fs, &f) == noErr ? f : nil
    }

    /// A copy of the tap's part of the input (its last `tapBuffers` buffers) as a CMSampleBuffer stamped with
    /// the host time of its first frame.
    private static func sampleBuffer(_ input: UnsafePointer<AudioBufferList>, tapBuffers: Int, time: AudioTimeStamp,
                                     asbd: AudioStreamBasicDescription, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard all.count >= tapBuffers, tapBuffers > 0 else { return nil }
        let skip = all.count - tapBuffers
        let first = all[skip]
        guard asbd.mBytesPerFrame > 0, first.mDataByteSize > 0 else { return nil }
        let frames = Int(first.mDataByteSize / asbd.mBytesPerFrame)
        guard frames > 0, time.mFlags.contains(.hostTimeValid) else { return nil }
        let pts = CMClockMakeHostTimeFromSystemUnits(time.mHostTime)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sb) == noErr, let sb
        else { return nil }
        // The whole input is the tap (the usual case): hand it over as is; otherwise a list of its buffers only.
        if skip == 0 {
            return CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                  flags: 0, bufferList: input) == noErr ? sb : nil
        }
        let tap = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        defer { free(tap.unsafeMutablePointer) }
        for i in 0..<tapBuffers { tap[i] = all[skip + i] }
        return CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                              flags: 0, bufferList: tap.unsafePointer) == noErr ? sb : nil
    }
}

// MARK: - Capture

@MainActor
final class Recorder: NSObject, SCStreamDelegate {
    enum Source { case mic, system }
    /// How system audio is captured: the process tap (hears FaceTime too) or ScreenCaptureKit.
    enum SystemCapture { case tap, screenCapture }

    /// ScreenCaptureKit streams: the first one captures the microphone (and system audio when the tap couldn't
    /// start); a source captured again gets a stream of its own.
    private var streams: Streams = []
    private var sink: AudioSink?
    private var filter: SCContentFilter?
    /// System audio through a process tap; nil when ScreenCaptureKit captures it.
    private var tap: SystemTap?
    /// Capture ended on its own (permission revoked, display changed): the error text.
    var onError: ((String) -> Void)?

    var systemCapture: SystemCapture { tap == nil ? .screenCapture : .tap }

    private static func configuration(_ sources: Set<Source>) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = sources.contains(.system)
        cfg.captureMicrophone = sources.contains(.mic)
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        // No video needed: a minimal frame once a second.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        return cfg
    }

    private func makeStream(_ sources: Set<Source>, filter: SCContentFilter, sink: AudioSink) throws -> SCStream {
        let s = SCStream(filter: filter, configuration: Self.configuration(sources), delegate: self)
        // Screen frames are accepted too (otherwise SCK complains in the log), but discarded.
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        if sources.contains(.system) { try s.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
        if sources.contains(.mic) { try s.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue) }
        return s
    }

    /// A new process tap into the sink, or nil (logged) when it can't start. Never with the System Audio
    /// Recording permission denied: such a tap starts but hears only zeros, and would replace a working capture.
    private func makeTap(_ sink: AudioSink) -> SystemTap? {
        if SystemAudioPermission.status == .denied {
            RecorderLog.write("system audio: the permission is off, ScreenCaptureKit instead of a process tap")
            return nil
        }
        do {
            return try SystemTap(sink: sink)
        } catch {
            RecorderLog.write("system audio: process tap \(error), ScreenCaptureKit instead")
            return nil
        }
    }

    /// Returns how system audio is captured: ScreenCaptureKit when the tap couldn't start (FaceTime unheard).
    @discardableResult
    func start(into dir: URL) async throws -> SystemCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Sozvon", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Нет дисплея для захвата")])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let sink = AudioSink(dir: dir)
        // The microphone first, then the process tap: creating the tap (an aggregate device) right before
        // ScreenCaptureKit opens the microphone made the first start after launch fail every time ("Stream
        // failed to start microphone"), and replayd then kept the microphone open.
        var started: Streams = []
        var tap: SystemTap?
        do {
            let mic = try makeStream([.mic], filter: filter, sink: sink)
            try await Self.startCapture(mic)
            started.append((mic, [.mic]))
            tap = makeTap(sink)
            if tap == nil {
                let system = try makeStream([.system], filter: filter, sink: sink)
                try await Self.startCapture(system)
                started.append((system, [.system]))
            }
            streams = started
        } catch {
            // Release everything that did start; the tap may already have written system.m4a: remove it,
            // or the folder would stay in "Calls".
            for s in started { await Self.stopCapture(s.stream) }
            tap?.stop()
            sink.discard()
            throw error
        }
        self.tap = tap
        self.sink = sink
        self.filter = filter
        if tap != nil { watchOutputDevice() }
        return systemCapture
    }

    /// Capture one source again (the default microphone or output may have changed, or the capture went deaf),
    /// without touching the other one. System audio goes to a new process tap; ScreenCaptureKit only when the
    /// tap can't start (it can't hear FaceTime). The new capture starts first, then the old one stops
    /// delivering this source, so the track gets no hole; the overlap is dropped by TrackWriter.
    /// Returns whether the new capture started.
    @discardableResult
    func recapture(_ source: Source) async -> Bool {
        guard let sink, let filter else { return false }
        if source == .system, let fresh = makeTap(sink) {
            let oldTap = tap
            tap = fresh
            oldTap?.stop()
            watchOutputDevice()
            RecorderLog.write("system audio: a new process tap")
            let old = streams
            streams = Self.without(.system, old)
            await detach(.system, from: old, sink: sink)
            return true
        }
        do {
            let s = try makeStream([source], filter: filter, sink: sink)
            try await Self.startCapture(s)
            guard self.sink === sink else { await Self.stopCapture(s); return false }  // stopped meanwhile
            let old = streams
            streams = Self.without(source, old) + [(s, Set([source]))]
            if source == .system {
                tap?.stop()
                tap = nil
            }
            RecorderLog.write("\(source == .mic ? "microphone" : "system audio"): captured again by ScreenCaptureKit")
            await detach(source, from: old, sink: sink)
            return true
        } catch {
            RecorderLog.write("capturing \(source) again failed: \(error)")
            return false
        }
    }

    private typealias Streams = [(stream: SCStream, sources: Set<Source>)]

    /// The streams with `source` taken off; a stream left with nothing is dropped.
    private static func without(_ source: Source, _ streams: Streams) -> Streams {
        streams.map { ($0.stream, $0.sources.subtracting([source])) }.filter { !$0.sources.isEmpty }
    }

    /// Stop the old streams delivering `source`: take their output off, and stop a stream left with nothing.
    /// A stream that keeps another source is reconfigured so it no longer captures this one (system audio
    /// moved to a tap: no second copy of the mix; the microphone captured again: the old device closes).
    /// `streams` is updated before this, so a `stop()` meanwhile never misses the new capture.
    private func detach(_ source: Source, from old: Streams, sink: AudioSink) async {
        let type: SCStreamOutputType = source == .system ? .audio : .microphone
        for s in old where s.sources.contains(source) {
            try? s.stream.removeStreamOutput(sink, type: type)
            let rest = s.sources.subtracting([source])
            if rest.isEmpty {
                await Self.stopCapture(s.stream)
            } else {
                do {
                    try await s.stream.updateConfiguration(Self.configuration(rest))
                } catch {
                    RecorderLog.write("reconfiguring the old stream without \(source) failed: \(error)")
                }
            }
        }
    }

    private var outputListener: AudioObjectPropertyListenerBlock?
    private static var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The default output changed (headphones, a FaceTime call again): the tap follows it.
    private func watchOutputDevice() {
        guard outputListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.tap != nil else { return }
                RecorderLog.write("system audio: the output device changed")
                await self.recapture(.system)
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, .main, block)
    }

    private func unwatchOutputDevice() {
        guard let block = outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.outputAddress, .main, block)
        outputListener = nil
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        let id = ObjectIdentifier(stream)
        Task { @MainActor in
            // A stream we already replaced may stop with an error: that is not the recording failing.
            guard self.streams.contains(where: { ObjectIdentifier($0.stream) == id }) else { return }
            RecorderLog.write("capture stopped: \(message)")
            self.onError?(message)
        }
    }

    /// Stop capture, close the files and return the track offsets (capture clock and wall clock).
    func stop() async -> (audio: AudioTimes, wall: AudioTimes) {
        unwatchOutputDevice()
        tap?.stop()
        tap = nil
        let running = streams
        streams = []
        filter = nil
        let sink = self.sink
        self.sink = nil
        for s in running { await Self.stopCapture(s.stream) }
        return sink?.finish() ?? (AudioTimes(), AudioTimes())
    }

    /// Start a stream, at most `startTimeout` seconds. ScreenCaptureKit's start can hang (a permission prompt
    /// that never resolves, a stuck replayd) while replayd already holds the microphone: then, and when the
    /// start fails, the stream is stopped, or the microphone would stay open even after Sozvon quits.
    static let startTimeout: Duration = .seconds(10)
    /// The error of a start that ran out of time (not worth retrying: another 10 seconds into the call).
    static func isTimeout(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == "Sozvon" && e.code == 2
    }
    private static func startCapture(_ stream: SCStream) async throws {
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<Void, Error>, Never>) in
            let once = Once()
            Task {
                do { try await stream.startCapture(); if once.claim() { done.resume(returning: .success(())) } }
                catch { if once.claim() { done.resume(returning: .failure(error)) } }
            }
            Task {
                try? await Task.sleep(for: startTimeout)
                if once.claim() {
                    done.resume(returning: .failure(NSError(domain: "Sozvon", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: L("Запись не запустилась: macOS не ответила за 10 секунд. Проверь разрешения Sozvon в Системных настройках и попробуй ещё раз."),
                    ])))
                }
            }
        }
        if case .failure(let error) = result {
            RecorderLog.write("starting the capture failed: \(error.localizedDescription)")
            await stopCapture(stream)
            throw error
        }
    }

    /// Stop a stream; a refusal is logged (usually: it had already stopped).
    private static func stopCapture(_ stream: SCStream) async {
        do { try await stream.stopCapture() } catch { RecorderLog.write("stopping the capture: \(error.localizedDescription)") }
    }

    /// Track levels for the panel.
    var meters: (mic: TrackWriter.Meter, system: TrackWriter.Meter) {
        (sink?.mic.meter ?? .init(), sink?.system.meter ?? .init())
    }
}

/// Lets exactly one of several racing callers through.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
