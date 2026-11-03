import XCTest
@testable import ListenookSpeechCore

final class QwenSpanPlannerTests: XCTestCase {
    func testSpeechBelowTenSecondsStaysPending() {
        XCTAssertEqual(
            forcedQwenSpans(
                startSample: 1_600,
                currentSample: 161_599,
                maximumSamples: 160_000
            ),
            []
        )
    }

    func testExactlyTenSecondsProducesOneBoundedSpan() {
        XCTAssertEqual(
            forcedQwenSpans(
                startSample: 1_600,
                currentSample: 161_600,
                maximumSamples: 160_000
            ),
            [1_600..<161_600]
        )
    }

    func testLongSpeechProducesSequentialTenSecondSpans() {
        XCTAssertEqual(
            forcedQwenSpans(
                startSample: 0,
                currentSample: 400_000,
                maximumSamples: 160_000
            ),
            [0..<160_000, 160_000..<320_000]
        )
    }
}
