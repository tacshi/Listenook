import Foundation

/// Returns owners whose aligned timestamps would be rejected by the Dart
/// boundary validator after clamping them to their authoritative MOSS segment.
func alignmentOwnersNeedingBoundaryRetry(
    tokens: [[String: Any]],
    segments: [[String: Any]]
) -> Set<String> {
    var rejected: Set<String> = []
    for segment in segments {
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
