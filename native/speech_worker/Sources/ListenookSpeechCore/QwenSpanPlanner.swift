import Foundation

func forcedQwenSpans(
    startSample: Int,
    currentSample: Int,
    maximumSamples: Int
) -> [Range<Int>] {
    guard maximumSamples > 0 else { return [] }
    var start = max(0, startSample)
    let current = max(start, currentSample)
    var spans: [Range<Int>] = []
    while current - start >= maximumSamples {
        let end = start + maximumSamples
        spans.append(start..<end)
        start = end
    }
    return spans
}
