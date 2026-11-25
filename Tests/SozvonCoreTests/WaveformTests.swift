import XCTest
@testable import SozvonCore

final class WaveformTests: XCTestCase {
    func testPeaks() {
        XCTAssertEqual(Waveform.peaks([0, 0.5, -1, 0.25], bins: 2), [0.5, 1])
        XCTAssertEqual(Waveform.peaks([0, 0, 0], bins: 3), [0, 0, 0])
        XCTAssertEqual(Waveform.peaks([], bins: 4).count, 4)
    }

    func testPeaksAlwaysGiveBinsValues() {
        // Fewer samples than bins: the bins between them stay zero, the count is still `bins`.
        XCTAssertEqual(Waveform.peaks([0.5, -0.25], bins: 4), [1, 0, 0.5, 0])
        XCTAssertEqual(Waveform.peaks(Array(repeating: 0.1, count: 1001), bins: 600).count, 600)
        XCTAssertEqual(Waveform.peaks([1], bins: 0), [])
    }

    func testEnvelopeOnTheCallTimeline() {
        // Two tracks of a 4 s call at 2 samples a second: the second starts 2 s later.
        var e = Waveform.Envelope(bins: 4, duration: 4)
        [Float(0.2), 0.2, 0.4, 0.4].withUnsafeBufferPointer { e.add($0, at: 0, rate: 2) }
        [Float(-0.8), 0.1, 0.3, 0.3].withUnsafeBufferPointer { e.add($0, at: 2, rate: 2) }
        XCTAssertEqual(e.peaks, [0.25, 0.5, 1, 0.375])
    }

    func testEnvelopeIgnoresSamplesOutsideTheCall() {
        var e = Waveform.Envelope(bins: 2, duration: 2)
        [Float(1), 0.5, 0.25, 1].withUnsafeBufferPointer { e.add($0, at: -1, rate: 1) }
        XCTAssertEqual(e.peaks, [1, 0.5])
        var empty = Waveform.Envelope(bins: 3, duration: 0)
        [Float(1)].withUnsafeBufferPointer { empty.add($0, at: 0, rate: 1) }
        XCTAssertEqual(empty.peaks, [0, 0, 0])
    }
}
