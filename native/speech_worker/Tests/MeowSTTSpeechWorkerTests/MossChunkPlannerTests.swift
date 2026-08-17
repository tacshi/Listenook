import XCTest
@testable import MeowSTTSpeechWorker

final class MossChunkPlannerTests: XCTestCase {
    func testSixtySecondsUsesTwoFullCapacityChunks() {
        let sampleRate = 100
        let samples = [Float](repeating: 0, count: sampleRate * 60)

        let boundaries = quietChunkBoundaries(
            samples: samples,
            sampleRate: sampleRate,
            maximumSeconds: 30
        )

        XCTAssertEqual(boundaries, [0, sampleRate * 30, sampleRate * 60])
    }

    func testLongAudioUsesTheMinimumChunkCountWithoutOversizedChunks() {
        let sampleRate = 100
        let durationSeconds = 831.338
        let samples = [Float](
            repeating: 0,
            count: Int(durationSeconds * Double(sampleRate))
        )

        let boundaries = quietChunkBoundaries(
            samples: samples,
            sampleRate: sampleRate,
            maximumSeconds: 30
        )
        let lengths = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }

        XCTAssertEqual(lengths.count, 28)
        XCTAssertTrue(lengths.allSatisfy { $0 <= sampleRate * 30 })
        XCTAssertTrue(lengths.allSatisfy { $0 >= sampleRate * 27 })
    }

    func testQuietCutIsChosenInsideTheFeasibleBalancedRange() {
        let sampleRate = 100
        var samples = [Float](repeating: 1, count: sampleRate * 59)
        let quietPoint = sampleRate * 29
        for index in (quietPoint - 10)..<(quietPoint + 10) {
            samples[index] = 0
        }

        let boundaries = quietChunkBoundaries(
            samples: samples,
            sampleRate: sampleRate,
            maximumSeconds: 30
        )

        XCTAssertEqual(boundaries.count, 3)
        XCTAssertLessThanOrEqual(abs(boundaries[1] - quietPoint), sampleRate / 10)
    }
}
