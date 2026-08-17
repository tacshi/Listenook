import Foundation

/// Plans the fewest Core ML encoder chunks while still preferring quiet cuts.
/// Every extra chunk pads and encodes another full 30-second Whisper window,
/// so a short accidental tail has a disproportionate cost.
func quietChunkBoundaries(
    samples: [Float],
    sampleRate: Int,
    maximumSeconds: Double
) -> [Int] {
    guard !samples.isEmpty, sampleRate > 0 else { return [0] }
    let maximum = max(1, Int(maximumSeconds * Double(sampleRate)))
    guard samples.count > maximum else { return [0, samples.count] }

    let chunkCount = Int(
        ceil(Double(samples.count) / Double(maximum))
    )
    let search = max(1, Int(2 * Double(sampleRate)))
    let preferredMinimum = max(1, Int(8 * Double(sampleRate)))
    let feasibleMinimum = max(1, samples.count / chunkCount)
    let minimum = min(maximum, preferredMinimum, feasibleMinimum)

    var boundaries = [0]
    var start = 0
    for boundaryIndex in 1..<chunkCount {
        let chunksAfterBoundary = chunkCount - boundaryIndex
        let chunksIncludingCurrent = chunksAfterBoundary + 1
        let balancedLength = Int(
            (Double(samples.count - start) / Double(chunksIncludingCurrent))
                .rounded()
        )
        let desired = start + min(maximum, balancedLength)

        // These capacity constraints guarantee that the remaining samples fit
        // in exactly the already-selected minimum number of chunks.
        let capacityLower = samples.count - chunksAfterBoundary * maximum
        let capacityUpper = samples.count - chunksAfterBoundary * minimum
        let lower = max(start + minimum, capacityLower, desired - search)
        let upper = min(start + maximum, capacityUpper, desired + search)
        let boundary = quietestPoint(
            samples: samples,
            lower: lower,
            upper: max(lower, upper),
            sampleRate: sampleRate
        )
        boundaries.append(boundary)
        start = boundary
    }
    boundaries.append(samples.count)
    return boundaries
}

func quietestPoint(
    samples: [Float],
    lower: Int,
    upper: Int,
    sampleRate: Int
) -> Int {
    guard upper > lower else { return lower }
    let analysis = max(1, Int(0.2 * Double(sampleRate)))
    let stride = max(1, Int(0.05 * Double(sampleRate)))
    var best = lower
    var bestEnergy = Double.greatestFiniteMagnitude
    var candidate = lower
    while candidate <= upper {
        let windowStart = max(0, candidate - analysis / 2)
        let windowEnd = min(samples.count, windowStart + analysis)
        var energy = 0.0
        if windowEnd > windowStart {
            for sample in samples[windowStart..<windowEnd] {
                energy += Double(abs(sample))
            }
            energy /= Double(windowEnd - windowStart)
        }
        if energy < bestEnergy {
            bestEnergy = energy
            best = candidate
        }
        candidate += stride
    }
    return best
}
