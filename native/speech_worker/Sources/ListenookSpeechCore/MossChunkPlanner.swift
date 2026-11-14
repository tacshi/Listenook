import Foundation

func quietChunkBoundaries(
    sampleCount: Int,
    sampleRate: Int,
    maximumSeconds: Double,
    chooseQuietPoint: (Int, Int) throws -> Int
) rethrows -> [Int] {
    guard sampleCount > 0, sampleRate > 0 else { return [0] }
    let maximum = max(1, Int(maximumSeconds * Double(sampleRate)))
    guard sampleCount > maximum else { return [0, sampleCount] }

    let chunkCount = Int(
        ceil(Double(sampleCount) / Double(maximum))
    )
    let search = max(1, Int(2 * Double(sampleRate)))
    let preferredMinimum = max(1, Int(8 * Double(sampleRate)))
    let feasibleMinimum = max(1, sampleCount / chunkCount)
    let minimum = min(maximum, preferredMinimum, feasibleMinimum)

    var boundaries = [0]
    var start = 0
    for boundaryIndex in 1..<chunkCount {
        let chunksAfterBoundary = chunkCount - boundaryIndex
        let chunksIncludingCurrent = chunksAfterBoundary + 1
        let balancedLength = Int(
            (Double(sampleCount - start) / Double(chunksIncludingCurrent))
                .rounded()
        )
        let desired = start + min(maximum, balancedLength)

        let capacityLower = sampleCount - chunksAfterBoundary * maximum
        let capacityUpper = sampleCount - chunksAfterBoundary * minimum
        let lower = max(start + minimum, capacityLower, desired - search)
        let upper = min(start + maximum, capacityUpper, desired + search)
        let boundary = try chooseQuietPoint(lower, max(lower, upper))
        boundaries.append(boundary)
        start = boundary
    }
    boundaries.append(sampleCount)
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
