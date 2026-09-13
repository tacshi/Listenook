import XCTest
@testable import ListenookSpeechWorker

final class AlignmentRecoveryTests: XCTestCase {
    func testOrderedTextRecursiveSplitRetainsOverlappingCueAudio() {
        let bounds = orderedAlignmentSplitBounds(
            startMs: 750,
            endMs: 30_250,
            leftSegments: [[
                "id": "rolling-1",
                "start_ms": 1_000,
                "end_ms": 28_000,
                "allow_outside_segment_bounds": true,
            ]],
            rightSegments: [[
                "id": "rolling-2",
                "start_ms": 25_000,
                "end_ms": 30_000,
                "allow_outside_segment_bounds": true,
            ]],
            paddingMs: 250
        )

        XCTAssertEqual(bounds?.count, 2)
        XCTAssertEqual(bounds?[0].startMs, 750)
        XCTAssertEqual(bounds?[0].endMs, 28_250)
        XCTAssertEqual(bounds?[1].startMs, 24_750)
        XCTAssertEqual(bounds?[1].endMs, 30_250)
        XCTAssertGreaterThan(bounds?[0].endMs ?? 0, bounds?[1].startMs ?? 0)
    }

    func testBoundaryRetryUsesTheAuthoritativeCueWithoutPadding() {
        let bounds = alignmentBoundaryRetryBounds(segment: [
            "id": "subtitle-cue-4214",
            "start_ms": 8_754_879,
            "end_ms": 8_757_278,
            "units": ["was"],
        ])

        XCTAssertEqual(bounds?.startMs, 8_754_879)
        XCTAssertEqual(bounds?.endMs, 8_757_278)
    }

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

    func testOrderedTextKeepsTokensOutsideDisplayCueBounds() {
        let segment: [[String: Any]] = [[
            "id": "rolling-2",
            "start_ms": 2_000,
            "end_ms": 7_000,
            "units": ["Charlie"],
            "allow_outside_segment_bounds": true,
        ]]

        XCTAssertTrue(
            alignmentOwnersNeedingBoundaryRetry(
                tokens: [token("rolling-2", 1_400, 1_900)],
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
