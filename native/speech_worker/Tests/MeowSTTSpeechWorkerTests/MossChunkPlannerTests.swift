import XCTest
@testable import MeowSTTSpeechWorker

final class MossChunkPlannerTests: XCTestCase {
    func testDetectsControlOnlyMossDecoderOutput() {
        XCTAssertTrue(
            isMossControlOnlyText(
                "[2.12][S01][2.62][18.28][S02][18.78]"
            )
        )
        XCTAssertTrue(
            isMossControlOnlyText(
                "[2.34][S01][2.84] [3.44][S01][3.94]"
            )
        )
        XCTAssertFalse(isMossControlOnlyText("[2.12][S01]Hello[2.62]"))
        XCTAssertFalse(isMossControlOnlyText("The speaker said [2.12]."))
        XCTAssertFalse(isMossControlOnlyText("[music]"))
    }

    func testSixtySecondsUsesTwoFullCapacityChunks() {
        let sampleRate = 100
        let samples = [Float](repeating: 0, count: sampleRate * 60)

        let boundaries = quietChunkBoundaries(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            maximumSeconds: 30,
            chooseQuietPoint: { lower, upper in
                quietestPoint(
                    samples: samples,
                    lower: lower,
                    upper: upper,
                    sampleRate: sampleRate
                )
            }
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
            sampleCount: samples.count,
            sampleRate: sampleRate,
            maximumSeconds: 30,
            chooseQuietPoint: { lower, upper in
                quietestPoint(
                    samples: samples,
                    lower: lower,
                    upper: upper,
                    sampleRate: sampleRate
                )
            }
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
            sampleCount: samples.count,
            sampleRate: sampleRate,
            maximumSeconds: 30,
            chooseQuietPoint: { lower, upper in
                quietestPoint(
                    samples: samples,
                    lower: lower,
                    upper: upper,
                    sampleRate: sampleRate
                )
            }
        )

        XCTAssertEqual(boundaries.count, 3)
        XCTAssertLessThanOrEqual(abs(boundaries[1] - quietPoint), sampleRate / 10)
    }

    func testFiveHoursPlansSixHundredChunksWithoutAnAudioArray() {
        let sampleRate = 16_000
        let sampleCount = sampleRate * 60 * 60 * 5
        var inspectedRanges: [(Int, Int)] = []

        let boundaries = quietChunkBoundaries(
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            maximumSeconds: 30,
            chooseQuietPoint: { lower, upper in
                inspectedRanges.append((lower, upper))
                return lower + (upper - lower) / 2
            }
        )
        let lengths = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }

        XCTAssertEqual(lengths.count, 600)
        XCTAssertEqual(inspectedRanges.count, 599)
        XCTAssertTrue(lengths.allSatisfy { $0 <= sampleRate * 30 })
        XCTAssertEqual(boundaries.last, sampleCount)
    }
}
