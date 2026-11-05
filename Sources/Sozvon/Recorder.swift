// Call audio capture: ScreenCaptureKit, two tracks in m4a (AAC).

import AVFoundation
import os
import ScreenCaptureKit
import SozvonCore

// MARK: - Single-track writer that fills gaps with silence

/// The track is written on the capture queue (AudioSink.queue): all its state is touched only there.
/// Only a level snapshot under a lock goes out to the main thread.
final class TrackWriter: @unchecked Sendable {
    struct Meter: Sendable {
        /// Latest signal level 0...1 (for the meter).
        var level: Float = 0
        var lastBufferAt: Date?
    }

    let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private(set) var firstPTS: Double?
    private var framesWritten: AVAudioFramePosition = 0
    private var loggedFormat: (Double, UInt32, UInt32, UInt32)?
    /// The track file already existed on disk: don't write.
    private var refused = false
    private let meterLock = OSAllocatedUnfairLock(initialState: Meter())

    init(url: URL) { self.url = url }

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
              let inFmt = TrackWriter.format(for: asbd) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        let level = Self.rms(inBuf)
        meterLock.withLock { $0 = Meter(level: level, lastBufferAt: Date()) }

        if file == nil {
            // A new recording always gets its own empty folder: never overwrite someone else's track.
            guard !refused else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                refused = true
                NSLog("Sozvon: \(url.path) already exists, not overwriting")
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
                format = f.processingFormat
                firstPTS = pts
            } catch {
                NSLog("Sozvon: cannot open \(url.path): \(error)")
                return
            }
        }
        guard let file, let format, let firstPTS else { return }

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
            NSLog("Sozvon: write error: \(error)")
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

    /// Log the track format (on the first packet and on change) to help debug microphone issues.
    private func logFormatOnce(_ a: AudioStreamBasicDescription) {
        let key = (a.mSampleRate, a.mFormatID, a.mChannelsPerFrame, a.mFormatFlags)
        if let l = loggedFormat, l == key { return }
        loggedFormat = key
        let id = String(bytes: withUnsafeBytes(of: a.mFormatID.bigEndian) { Array($0) }, encoding: .ascii) ?? "\(a.mFormatID)"
        let line = "\(Date()) \(url.lastPathComponent): \(id) \(a.mSampleRate) Hz, \(a.mChannelsPerFrame) ch, "
            + "\(a.mBitsPerChannel) bit, flags \(a.mFormatFlags), bytes/frame \(a.mBytesPerFrame)\n"
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

    /// RMS of the first channel, mapped to 0...1 on a -50...0 dB scale.
    static func rms(_ buf: AVAudioPCMBuffer) -> Float {
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let f = buf.floatChannelData?[0] {
            for i in 0..<n { sum += f[i] * f[i] }
        } else if let s16 = buf.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(s16[i]) / 32768; sum += v * v }
        } else {
            return 0
        }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 50))
    }

    func close() {
        file?.close()
        file = nil
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

    init(dir: URL) {
        system = TrackWriter(url: dir.appendingPathComponent("system.m4a"))
        mic = TrackWriter(url: dir.appendingPathComponent("mic.m4a"))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: system.append(sb)
        case .microphone: mic.append(sb)
        default: break
        }
    }

    /// Close the files (after capture stops) and return the track start offsets.
    func finish() -> AudioTimes {
        queue.sync {
            system.close()
            mic.close()
            return AudioTimes(micStart: mic.firstPTS, systemStart: system.firstPTS,
                              micSeconds: mic.seconds, systemSeconds: system.seconds)
        }
    }
}

// MARK: - ScreenCaptureKit capture

@MainActor
final class Recorder: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var sink: AudioSink?
    /// Capture ended on its own (permission revoked, display changed): the error text.
    var onError: ((String) -> Void)?

    func start(into dir: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Sozvon", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Нет дисплея для захвата")])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.captureMicrophone = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        // No video needed: a minimal frame once a second.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false

        let sink = AudioSink(dir: dir)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        // Screen frames are accepted too (otherwise SCK complains in the log), but discarded.
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try s.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
        try s.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
        try await s.startCapture()
        stream = s
        self.sink = sink
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in self.onError?(message) }
    }

    /// Stop capture, close the files and return the track offsets.
    func stop() async -> AudioTimes {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        defer { sink = nil }
        return sink?.finish() ?? AudioTimes()
    }

    /// Track levels for the panel.
    var meters: (mic: TrackWriter.Meter, system: TrackWriter.Meter) {
        (sink?.mic.meter ?? .init(), sink?.system.meter ?? .init())
    }
}
