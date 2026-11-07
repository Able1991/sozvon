// Playing a call in the Calls window: the mic and system tracks mixed in sync (an AVMutableComposition with
// each track inserted at its start offset, the same timeline as the transcript), and a compact player bar.

import AVFoundation
import SozvonCore
import SwiftUI

/// The transcript line being played. Separate from the player, so the transcript redraws only when
/// the line changes, not on every time tick.
@MainActor
final class PlayingLine: ObservableObject {
    /// Playback time once playback started (nil before): the transcript works out its current line from the
    /// text it shows, so a transcript rewritten underneath (renamed, transcribed again) can never be out of step.
    @Published var time: Double?

    /// The current paragraph in `starts` (non-decreasing paragraph start times).
    func index(in starts: [TimeInterval]) -> Int? {
        time.flatMap { Transcript.lineIndex(at: $0 + 0.05, starts: starts) }
    }
}

@MainActor
final class CallPlayer: ObservableObject {
    static let rates: [Float] = [1, 1.5, 2]

    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var ready = false
    /// The tracks could not be read: the bar says so instead of waiting forever.
    @Published private(set) var failed = false
    @Published var rate: Float = 1 {
        didSet {
            player?.defaultRate = rate
            if isPlaying { player?.rate = rate }
        }
    }
    let line = PlayingLine()

    private let dir: URL
    private var player: AVPlayer?
    private var observer: Any?
    private var loading: Task<Void, Never>?
    /// Something was played: from then on the current line is highlighted.
    private var started = false
    private var scrubbing = false
    /// A seek is in flight: AVPlayer keeps reporting the old time until it lands, which made the
    /// highlight jump back to the previous line after a click. Ticks are ignored until then.
    private var seekGeneration = 0
    private var seeking = false
    /// A line clicked before the mix was ready: played from there as soon as it is.
    private var queuedStart: Double?

    init(dir: URL) { self.dir = dir }

    /// Build the mix on first need (opening the transcript); cheap, nothing is decoded up front.
    func prepare() {
        guard player == nil, loading == nil else { return }
        loading = Task { [weak self, dir] in
            let comp = await Self.composition(dir)
            guard let self, !Task.isCancelled else { return }
            guard let comp else {
                // Nothing to play: drop a queued click and its highlight.
                self.queuedStart = nil
                self.started = false
                self.updateLine()
                self.failed = true
                // Let a later prepare() (the call's audio appears, e.g. an import finishes) try again.
                self.loading = nil
                return
            }
            let item = AVPlayerItem(asset: comp)
            item.audioTimePitchAlgorithm = .timeDomain  // 1.5x and 2x without chipmunk voices
            let p = AVPlayer(playerItem: item)
            p.defaultRate = self.rate
            self.player = p
            self.duration = comp.duration.seconds.isFinite ? comp.duration.seconds : 0
            self.observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
                MainActor.assumeIsolated { self?.tick(t.seconds) }
            }
            self.ready = true
            if let t = self.queuedStart {
                self.queuedStart = nil
                self.seek(t)
                self.toggle()
            }
        }
    }

    /// Mic and system tracks at their offsets (TrackOffsets, as in the engine). nil: no readable track.
    private static func composition(_ dir: URL) async -> AVMutableComposition? {
        let offsets = TrackOffsets(TrackOffsets.times(of: dir))
        let comp = AVMutableComposition()
        // The engine's cleaned microphone (echo removed, a quiet voice raised) when there is one: it is already
        // aligned to the call's start, so it plays at offset 0. Otherwise the original mic track.
        let clean = FileManager.default.fileExists(atPath: dir.appendingPathComponent(AudioRetention.cleanMic).path)
        let mic = clean ? (AudioRetention.cleanMic, 0.0) : ("mic.m4a", offsets.mic)
        for (name, offset) in [mic, ("system.m4a", offsets.system)] {
            let url = dir.appendingPathComponent(name)
            // Same threshold as the engine's tracks.track_files: a smaller file is a track that never recorded.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 1024 else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await track.load(.timeRange),
                  let out = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? out.insertTimeRange(range, of: track, at: CMTime(seconds: max(0, offset), preferredTimescale: 48000))
        }
        return comp.tracks.isEmpty ? nil : comp
    }

    private func tick(_ t: Double) {
        guard let player, !scrubbing, !seeking else { return }
        if t.isFinite { time = t }
        let playing = player.rate != 0
        if playing != isPlaying { isPlaying = playing }
        updateLine()
    }

    private func updateLine() {
        let t: Double? = started ? time : nil
        if line.time != t { line.time = t }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, time >= duration - 0.25 { seek(0) }
            started = true
            player.playImmediately(atRate: rate)
            isPlaying = true
            updateLine()
        }
    }

    func seek(_ t: Double) {
        // Before the mix is loaded the duration is unknown (0): don't clamp a queued start to it.
        let t = player == nil ? max(0, t) : min(max(0, t), max(0, duration))
        time = t
        updateLine()
        guard let player else { return }
        seekGeneration += 1
        let gen = seekGeneration
        seeking = true
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor in
                // Only the latest seek ends the guard: quick clicks on several lines don't flicker.
                guard let self, gen == self.seekGeneration else { return }
                self.seeking = false
            }
        }
    }

    /// A click on a transcript line: jump there and play. Before the mix is ready the click is queued
    /// (the line stays highlighted) and applied at the end of prepare().
    func play(from t: Double) {
        guard !failed else { return }
        started = true
        guard player != nil else {
            queuedStart = max(0, t)
            time = max(0, t)
            updateLine()
            prepare()
            return
        }
        seek(t)
        if !isPlaying { toggle() }
    }

    /// Jump back or forward by a few seconds (the -15 / +15 buttons).
    func skip(_ seconds: Double) {
        seek(time + seconds)
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func scrub(_ editing: Bool) { scrubbing = editing }

    /// The scrubber moved: while dragging only the shown time follows (the seek comes on release); a step
    /// without a drag (arrow keys, VoiceOver increment) seeks right away.
    func scrubbed(to t: Double) {
        if scrubbing { time = t } else { seek(t) }
    }

    /// Selection changed (the detail view is gone): free the player and the files it holds open.
    func stop() {
        loading?.cancel()
        loading = nil
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        ready = false
        failed = false
        isPlaying = false
        queuedStart = nil
    }
}

/// The player bar: -15, play/pause, +15, time, scrubber, duration, speed. Bar glass under the call card.
/// Tracks that can't be read: "Recording unavailable" in its place.
struct PlayerBar: View {
    @ObservedObject var player: CallPlayer
    /// The call has a transcript: the "unavailable" line says it is still there.
    var hasTranscript = true

    var body: some View {
        Group {
            if player.failed {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.slash").font(.system(size: 12)).accessibilityHidden(true)
                    Text(hasTranscript ? L("Запись недоступна: звуковые дорожки не читаются. Расшифровка и саммари остались.")
                         : L("Запись недоступна: звуковые дорожки не читаются."))
                        .lineLimit(2)
                }
                .foregroundStyle(SZ.label2)
                .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                controls
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .modifier(PlayerGlass())
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func skip(_ symbol: String, _ label: String, _ seconds: Double) -> some View {
        Button { player.skip(seconds) } label: {
            Image(systemName: symbol).font(.system(size: 16))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            skip("gobackward.15", L("Назад на 15 секунд"), -15)
            // While the mix loads the button is dimmed; a click on a line waits for it and then plays.
            SZPlayButton(playing: player.isPlaying, action: player.toggle)
                .opacity(player.ready ? 1 : 0.5)
                .help(player.isPlaying ? L("Пауза") : L("Слушать"))
                .accessibilityLabel(player.isPlaying ? L("Пауза") : L("Слушать"))
            skip("goforward.15", L("Вперёд на 15 секунд"), 15)
            Text(Call.clock(Int(player.time), empty: "0:00"))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            SZScrubber(value: Binding(get: { player.time }, set: { player.scrubbed(to: $0) }),
                       range: 0...max(player.duration, 1)) { editing in
                player.scrub(editing)
                if !editing { player.seek(player.time) }
            }
            .accessibilityLabel(L("Позиция"))
            Text(Call.clock(Int(player.duration), empty: "0:00"))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
            SZRateMenu(rate: $player.rate, rates: CallPlayer.rates)
        }
        .disabled(!player.ready)
    }
}

/// The player floats over the transcript as a Liquid Glass capsule on macOS 26 (a bar material before).
private struct PlayerGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.bar, in: Capsule())
        }
    }
}
