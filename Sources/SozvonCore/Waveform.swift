// The waveform of a whole call for the trim panel: the loudest sample in each of a fixed number of bins,
// normalized to the loudest bin. The app decodes the playback mix at a low rate and feeds it here.

import Foundation

public enum Waveform {
    /// Max absolute sample per bin, normalized to the loudest bin; silence stays all zeros.
    /// Always `bins` values (zeros for bins no sample falls into).
    public static func peaks(_ samples: [Float], bins: Int) -> [Float] {
        var e = Envelope(bins: bins, duration: Double(samples.count))
        samples.withUnsafeBufferPointer { e.add($0, at: 0, rate: 1) }
        return e.peaks
    }

    /// Peaks gathered over the call's timeline from several tracks at their offsets, a chunk at a time
    /// (a long call never sits in memory as samples).
    public struct Envelope: Sendable {
        public let bins: Int
        public let duration: Double
        private var raw: [Float]

        public init(bins: Int, duration: Double) {
            self.bins = max(0, bins)
            self.duration = duration
            raw = Array(repeating: 0, count: self.bins)
        }

        /// Samples at `rate` per second starting at `start` seconds on the call's timeline. Samples before
        /// the call's start or at or after its end are left out.
        public mutating func add(_ samples: UnsafeBufferPointer<Float>, at start: Double, rate: Double) {
            guard bins > 0, duration > 0, rate > 0 else { return }
            let scale = Double(bins) / duration
            raw.withUnsafeMutableBufferPointer { out in
                for (i, s) in samples.enumerated() {
                    let t = start + Double(i) / rate
                    guard t >= 0, t < duration else { continue }
                    let b = min(bins - 1, Int(t * scale))
                    let v = abs(s)
                    if v > out[b] { out[b] = v }
                }
            }
        }

        /// Normalized to the loudest bin (all zeros when nothing was heard).
        public var peaks: [Float] {
            guard let top = raw.max(), top > 0 else { return raw }
            return raw.map { $0 / top }
        }
    }
}
