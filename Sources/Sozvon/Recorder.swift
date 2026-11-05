// Захват звука звонка: ScreenCaptureKit, две дорожки в m4a (AAC).

import AVFoundation
import os
import ScreenCaptureKit
import SozvonCore

// MARK: - Запись одной дорожки с заполнением пауз тишиной

/// Дорожка пишется на очереди захвата (AudioSink.queue): всё её состояние трогается только там.
/// Наружу, на главный поток, уходит лишь снимок уровня под замком.
final class TrackWriter: @unchecked Sendable {
    struct Meter: Sendable {
        /// Последний уровень сигнала 0...1 (для индикатора).
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
    /// Файл дорожки уже был на диске: не пишем.
    private var refused = false
    private let meterLock = OSAllocatedUnfairLock(initialState: Meter())

    init(url: URL) { self.url = url }

    /// Уровень и время последнего пакета: читается с любого потока.
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
        // Только линейный PCM: иначе AVAudioPCMBuffer падает (SIGSEGV).
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
            // Папка новой записи всегда своя и пустая: чужую дорожку не перезаписываем.
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

        // Формат мог смениться на лету (подключили AirPods): конвертируем в исходный.
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

        // Если поток прерывался (тишина в системе), дописываем нули, чтобы время не уезжало.
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

    /// Формат входа. AVAudioFormat(cmAudioFormatDescription:) на некоторых микрофонах (гарнитуры в режиме
    /// разговора, многоканальные устройства без раскладки) отдаёт nil и роняет приложение, поэтому
    /// собираем формат из ASBD сами, для >2 каналов с явной раскладкой.
    static func format(for asbd: AudioStreamBasicDescription) -> AVAudioFormat? {
        var d = asbd
        if d.mChannelsPerFrame <= 2, let f = AVAudioFormat(streamDescription: &d) { return f }
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(d.mChannelsPerFrame)
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(streamDescription: &d, channelLayout: layout)
    }

    /// Записать в журнал формат дорожки (при первом пакете и при смене): для разбора проблем с микрофоном.
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

    /// RMS первого канала, приведённый к 0...1 по шкале -50...0 dB.
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

/// Один входной буфер для AVAudioConverter: отдаётся один раз. Конвертер зовёт блок
/// синхронно внутри convert, на той же очереди, поэтому без замка.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ b: AVAudioPCMBuffer) { buffer = b }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

// MARK: - Приёмник пакетов захвата

/// Получает пакеты на своей очереди и раскладывает по дорожкам. Дорожки неизменны на всю запись,
/// поэтому приёмник безопасно отдавать ScreenCaptureKit.
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

    /// Закрыть файлы (после остановки захвата) и вернуть смещения начала дорожек.
    func finish() -> AudioTimes {
        queue.sync {
            system.close()
            mic.close()
            return AudioTimes(micStart: mic.firstPTS, systemStart: system.firstPTS,
                              micSeconds: mic.seconds, systemSeconds: system.seconds)
        }
    }
}

// MARK: - Захват через ScreenCaptureKit

@MainActor
final class Recorder: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var sink: AudioSink?
    /// Захват оборвался сам (отозвали разрешение, сменился дисплей): текст ошибки.
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
        // Видео не нужно: минимальный кадр раз в секунду.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false

        let sink = AudioSink(dir: dir)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        // Кадры экрана тоже принимаем (иначе SCK ругается в журнал), но отбрасываем.
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

    /// Остановить захват, закрыть файлы и вернуть смещения дорожек.
    func stop() async -> AudioTimes {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        defer { sink = nil }
        return sink?.finish() ?? AudioTimes()
    }

    /// Уровни дорожек для панели.
    var meters: (mic: TrackWriter.Meter, system: TrackWriter.Meter) {
        (sink?.mic.meter ?? .init(), sink?.system.meter ?? .init())
    }
}
