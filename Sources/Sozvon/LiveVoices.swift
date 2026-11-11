// Who is on the call, known by the end of it: while recording, the other side's track is also cut into one
// minute pieces (16 kHz mono WAV in <call>/.live/), and `voice.py live` matches them against the saved voices
// (engine/sozvon_engine/live_voices.py). When the recording stops, the tally fills "What was the call about?"
// together with the calendar. Only when there are voices of other people to match; at utility priority.

import AVFoundation
import Foundation
import SozvonCore

/// Cuts a track into pieces for the live match. Called on the sink's queue only.
final class LivePieces: @unchecked Sendable {
    static let folder = ".live"
    static let seconds: Double = 60
    static let rate: Double = 16000

    let dir: URL
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var count = 0
    private let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LivePieces.rate, channels: 1, interleaved: false)!

    init(dir: URL) {
        self.dir = dir
        samples.reserveCapacity(Int(Self.seconds * Self.rate) + 4096)
    }

    /// A buffer just written to the track (the track's processing format).
    func add(_ buf: AVAudioPCMBuffer) {
        if converter.map({ !$0.inputFormat.isEqual(buf.format) }) ?? true {
            converter = AVAudioConverter(from: buf.format, to: out)
            converter?.downmix = true  // both channels of a stereo mix, not just the left one
        }
        guard let converter,
              let res = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * Self.rate / buf.format.sampleRate) + 512)
        else { return }
        let input = OneShotInput(buf)
        var err: NSError?
        converter.convert(to: res, error: &err) { _, status in
            guard let b = input.take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return b
        }
        guard err == nil, res.frameLength > 0, let p = res.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(res.frameLength)))
        if Double(samples.count) >= Self.seconds * Self.rate { flush() }
    }

    /// The rest as the last piece (the recording ended); a couple of seconds are not worth matching.
    func finish() {
        if Double(samples.count) >= 2 * Self.rate { flush() }
        samples.removeAll()
    }

    private func flush() {
        defer { samples.removeAll(keepingCapacity: true) }
        count += 1
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(format: "system-%04d", count)
        let tmp = dir.appendingPathComponent(".\(name).tmp.wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        guard let buf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: AVAudioFrameCount(samples.count)),
              let p = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: samples.count) }
        do {
            // Closed before the rename: the engine never sees a half-written piece.
            try autoreleasepool {
                let f = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try f.write(from: buf)
            }
            try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent(name + ".wav"))
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            RecorderLog.write("live voices: piece \(name) not written: \(error)")
        }
    }
}

/// One person the live match heard (voices.json).
struct LiveVoice: Equatable, Sendable {
    let name: String
    let profile: String
    let seconds: Double
    let unsure: Bool
}

@MainActor
final class LiveVoices {
    static let shared = LiveVoices()
    private var process: RunningProcess?
    private var running: URL?
    private var generation = 0
    private var finishing = false
    /// `finish` waiting for the engine to exit, and which wait it is (a late timeout of an earlier wait must not end this one).
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitID = 0

    /// From the start of the recording until the last piece is matched: the transcription queue waits, a Whisper run
    /// next to the last piece would push it past the 15 seconds `finish` gives it.
    var isActive: Bool { running != nil || finishing }

    /// Worth running: the engine works and someone else's voice is saved.
    static var useful: Bool {
        EngineState.current.isUsable
            && VoiceStore.shared.records.contains { !$0.me }
    }

    static func folder(_ call: URL) -> URL { call.appendingPathComponent(LivePieces.folder) }

    /// The recording started in `call`: match the pieces as they come.
    func start(_ call: URL) {
        guard process == nil, Self.useful else { return }
        let dir = Self.folder(call)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        running = call
        generation += 1
        let run = generation
        let (exe, argv) = Engine.command(Paths.engineScript(Voices.script), ["live", "--dir", dir.path], gentle: true)
        process = ProcessRunner.run(exe, argv, environment: Engine.environment(gentle: true), currentDirectory: Paths.data,
                                    log: dir.appendingPathComponent("live.log")) { [weak self] _ in
            guard let self, self.generation == run else { return }
            self.process = nil
            self.endWait()
        }
    }

    /// The recording stopped (its last piece is written): who was heard. Waits a little for the last piece.
    func finish(_ call: URL) async -> [LiveVoice] {
        let dir = Self.folder(call)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard running == call else { return [] }
        finishing = true
        defer { finishing = false }
        running = nil
        FileManager.default.createFile(atPath: dir.appendingPathComponent("stop").path, contents: nil)
        // The engine finishes the last piece and exits (the done callback of `start` wakes this up);
        // at most 15 seconds, then it is stopped.
        if process != nil {
            waitID += 1
            let id = waitID
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiter = c
                mainAfter(15) { [weak self] in if self?.waitID == id { self?.endWait() } }
            }
        }
        process?.terminate()
        process = nil
        return Self.read(dir.appendingPathComponent("voices.json"))
    }

    private func endWait() {
        let w = waiter
        waiter = nil
        w?.resume()
    }

    /// Sozvon is quitting: the pieces are of no use to anyone now.
    func abandon() {
        process?.terminate()
        process = nil
        endWait()
        if let call = running { try? FileManager.default.removeItem(at: Self.folder(call)) }
        running = nil
    }

    /// At launch: pieces left by a crash or a quit in the middle of a recording. Raw speech of the other side
    /// must not outlive the recording. Nothing is being recorded yet at this point.
    static func sweep() {
        let calls = Paths.calls
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for dir in (try? fm.contentsOfDirectory(at: calls, includingPropertiesForKeys: nil)) ?? [] {
                let live = dir.appendingPathComponent(LivePieces.folder)
                if fm.fileExists(atPath: live.path) { try? fm.removeItem(at: live) }
            }
        }
    }

    static func read(_ url: URL) -> [LiveVoice] {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = o["voices"] as? [[String: Any]] else { return [] }
        return list.compactMap { v in
            guard let name = v["name"] as? String, !name.isEmpty else { return nil }
            return LiveVoice(name: name, profile: v["profile"] as? String ?? "", seconds: v["seconds"] as? Double ?? 0,
                             unsure: v["unsure"] as? Bool ?? false)
        }
    }
}
