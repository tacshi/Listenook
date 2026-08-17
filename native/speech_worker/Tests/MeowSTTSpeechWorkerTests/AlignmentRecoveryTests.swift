import XCTest
@testable import MeowSTTSpeechWorker

final class AlignmentRecoveryTests: XCTestCase {
    func testRequestsRetryWhenContextPushesEveryTokenPastSegmentEnd() {
        let segment: [[String: Any]] = [[
            "id": "moss-295",
            "start_ms": 560_919,
            "end_ms": 561_329,
            "units": ["它", "都", "是"],
        ]]
        let tokens: [[String: Any]] = [
            token("moss-295", 561_449, 561_529),
            token("moss-295", 561_529, 561_609),
            token("moss-295", 561_609, 561_769),
        ]

        XCTAssertEqual(
            alignmentOwnersNeedingBoundaryRetry(
                tokens: tokens,
                segments: segment
            ),
            ["moss-295"]
        )
    }

    func testKeepsReliableTokensInsideSegment() {
        let segment: [[String: Any]] = [[
            "id": "moss-295",
            "start_ms": 560_919,
            "end_ms": 561_329,
            "units": ["它", "都", "是"],
        ]]
        let tokens: [[String: Any]] = [
            token("moss-295", 560_929, 561_009),
            token("moss-295", 561_009, 561_169),
            token("moss-295", 561_169, 561_249),
        ]

        XCTAssertTrue(
            alignmentOwnersNeedingBoundaryRetry(
                tokens: tokens,
                segments: segment
            ).isEmpty
        )
    }

    func testRequestsRetryWhenSentenceTailFallsPastSegmentEnd() {
        let segment: [[String: Any]] = [[
            "id": "moss-tail",
            "start_ms": 10_000,
            "end_ms": 10_600,
            "units": ["分", "享", "一", "下"],
        ]]
        let tokens: [[String: Any]] = [
            token("moss-tail", 10_050, 10_200),
            token("moss-tail", 10_200, 10_600),
            token("moss-tail", 10_640, 10_720),
            token("moss-tail", 10_720, 10_800),
        ]

        XCTAssertEqual(
            alignmentOwnersNeedingBoundaryRetry(
                tokens: tokens,
                segments: segment
            ),
            ["moss-tail"]
        )
    }

    func testKeepsSingleTiedTimestampClassInsideSegment() {
        let segment: [[String: Any]] = [[
            "id": "moss-134",
            "start_ms": 258_870,
            "end_ms": 259_090,
            "units": ["啊"],
        ]]

        XCTAssertTrue(
            alignmentOwnersNeedingBoundaryRetry(
                tokens: [token("moss-134", 258_950, 258_950)],
                segments: segment
            ).isEmpty
        )
    }

    private func token(
        _ owner: String,
        _ startMs: Int,
        _ endMs: Int
    ) -> [String: Any] {
        [
            "segment_id": owner,
            "start_ms": startMs,
            "end_ms": endMs,
        ]
    }
}
