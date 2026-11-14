import Foundation

func orderedAlignmentSplitBounds(
    startMs: Int,
    endMs: Int,
    leftSegments: [[String: Any]],
    rightSegments: [[String: Any]],
    paddingMs: Int
) -> [(startMs: Int, endMs: Int)]? {
    let segments = leftSegments + rightSegments
    guard endMs - startMs > 1,
          !leftSegments.isEmpty,
          !rightSegments.isEmpty,
          let leftEnd = leftSegments.compactMap({
              ($0["end_ms"] as? NSNumber)?.intValue
          }).max(),
          let rightStart = rightSegments.compactMap({
              ($0["start_ms"] as? NSNumber)?.intValue
          }).min(),
          segments.allSatisfy({
              $0["allow_outside_segment_bounds"] as? Bool == true
          })
    else { return nil }
    let paddedLeftEnd = min(endMs, leftEnd + max(0, paddingMs))
    let paddedRightStart = max(startMs, rightStart - max(0, paddingMs))
    guard paddedLeftEnd > startMs, endMs > paddedRightStart else { return nil }
    return [
        (startMs: startMs, endMs: paddedLeftEnd),
        (startMs: paddedRightStart, endMs: endMs),
    ]
}

func alignmentBoundaryRetryBounds(
    segment: [String: Any]
) -> (startMs: Int, endMs: Int)? {
    guard let startMs = (segment["start_ms"] as? NSNumber)?.intValue,
          let endMs = (segment["end_ms"] as? NSNumber)?.intValue,
          startMs >= 0,
          endMs > startMs
    else { return nil }
    return (startMs, endMs)
}

func alignmentOwnersNeedingBoundaryRetry(
    tokens: [[String: Any]],
    segments: [[String: Any]]
) -> Set<String> {
    var rejected: Set<String> = []
    for segment in segments {
        if segment["allow_outside_segment_bounds"] as? Bool == true {
            continue
        }
        guard let owner = segment["id"] as? String,
              let segmentStart = (segment["start_ms"] as? NSNumber)?.intValue,
              let segmentEnd = (segment["end_ms"] as? NSNumber)?.intValue,
              let units = segment["units"] as? [String]
        else { continue }
        let owned = tokens.filter { $0["segment_id"] as? String == owner }
        guard owned.count == units.count else {
            rejected.insert(owner)
            continue
        }

        var clamped: [(Int, Int)] = []
        var hasClampedBoundaryPoint = false
        var invalid = false
        for token in owned {
            guard let rawStart = (token["start_ms"] as? NSNumber)?.intValue,
                  let rawEnd = (token["end_ms"] as? NSNumber)?.intValue,
                  rawEnd >= rawStart
            else {
                invalid = true
                break
            }
            let start = min(segmentEnd, max(segmentStart, rawStart))
            let end = min(segmentEnd, max(start, rawEnd))
            let tiedTimestampClass = rawStart == rawEnd
                && rawStart >= segmentStart
                && rawStart < segmentEnd
            if end == start && !tiedTimestampClass {
                hasClampedBoundaryPoint = true
            }
            if let previous = clamped.last,
               (start < previous.0 || end < previous.1)
            {
                invalid = true
                break
            }
            clamped.append((start, end))
        }
        let allCollapsed = clamped.count > 1
            && clamped.allSatisfy {
                $0.0 == clamped[0].0 && $0.1 == clamped[0].1
            }
        let tailCollapsedAtEnd = clamped.last.map {
            $0.0 == segmentEnd && $0.1 == segmentEnd
        } ?? false
        if invalid
            || (clamped.count == 1 && hasClampedBoundaryPoint)
            || tailCollapsedAtEnd
            || allCollapsed
        {
            rejected.insert(owner)
        }
    }
    return rejected
}
