import Foundation
import XCTest
@testable import ListenookSpeechCore

final class PCM16WaveFileTests: XCTestCase {
    func testReadsOnlyTheRequestedStandardPCMRange() throws {
        let fixture = try temporaryWave(
            samples: [0, 1_000, -2_000, 32_767, -32_768],
            extensible: false
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let wave = try PCM16WaveFile(path: fixture.path)
        let samples = try wave.readSamples(2..<4)

        XCTAssertEqual(wave.sampleRate, 16_000)
        XCTAssertEqual(wave.sampleCount, 5)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0], -2_000 / 32_768, accuracy: 0.000_001)
        XCTAssertEqual(samples[1], 32_767 / 32_768, accuracy: 0.000_001)
    }

    func testReadsWaveFormatExtensiblePCM() throws {
        let fixture = try temporaryWave(
            samples: [1_000, -1_000],
            extensible: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let wave = try PCM16WaveFile(path: fixture.path)
        let samples = try wave.readSamples(0..<2)

        XCTAssertEqual(samples[0], 1_000 / 32_768, accuracy: 0.000_001)
        XCTAssertEqual(samples[1], -1_000 / 32_768, accuracy: 0.000_001)
    }

    func testAcceptsAnEmptyPCMStream() throws {
        let fixture = try temporaryWave(samples: [], extensible: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let wave = try PCM16WaveFile(path: fixture.path)

        XCTAssertEqual(wave.sampleCount, 0)
        XCTAssertEqual(try wave.readSamples(0..<0), [])
    }

    func testReadsTheTailOfASparseFiveHourWave() throws {
        let sampleCount = 16_000 * 60 * 60 * 5
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "listenook-wave-sparse-\(UUID().uuidString).wav"
        )
        FileManager.default.createFile(atPath: fixture.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fixture)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: fixture)
        }
        try handle.write(contentsOf: waveHeader(dataBytes: sampleCount * 2))
        try handle.truncate(atOffset: UInt64(44 + sampleCount * 2))
        try handle.seek(toOffset: UInt64(44 + (sampleCount - 2) * 2))
        try handle.write(contentsOf: pcmData([12_345, -12_345]))
        try handle.synchronize()

        let wave = try PCM16WaveFile(path: fixture.path)
        let samples = try wave.readSamples((sampleCount - 2)..<sampleCount)

        XCTAssertEqual(wave.sampleCount, sampleCount)
        XCTAssertEqual(samples[0], 12_345 / 32_768, accuracy: 0.000_001)
        XCTAssertEqual(samples[1], -12_345 / 32_768, accuracy: 0.000_001)
    }

    func testRejectsATruncatedDataChunk() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "listenook-wave-truncated-\(UUID().uuidString).wav"
        )
        var data = waveHeader(dataBytes: 4)
        data.append(contentsOf: [0, 0])
        try data.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        XCTAssertThrowsError(try PCM16WaveFile(path: fixture.path)) { error in
            XCTAssertEqual(error as? PCM16WaveFileError, .invalid)
        }
    }

    private func temporaryWave(
        samples: [Int16],
        extensible: Bool
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "listenook-wave-\(UUID().uuidString).wav"
        )
        var data = extensible
            ? extensibleWaveHeader(dataBytes: samples.count * 2)
            : waveHeader(dataBytes: samples.count * 2)
        data.append(pcmData(samples))
        try data.write(to: url)
        return url
    }

    private func waveHeader(dataBytes: Int) -> Data {
        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32(UInt32(36 + dataBytes))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32(16)
        data.appendUInt16(1)
        data.appendUInt16(1)
        data.appendUInt32(16_000)
        data.appendUInt32(32_000)
        data.appendUInt16(2)
        data.appendUInt16(16)
        data.appendASCII("data")
        data.appendUInt32(UInt32(dataBytes))
        return data
    }

    private func extensibleWaveHeader(dataBytes: Int) -> Data {
        var data = Data()
        data.appendASCII("RIFF")
        data.appendUInt32(UInt32(60 + dataBytes))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendUInt32(40)
        data.appendUInt16(0xfffe)
        data.appendUInt16(1)
        data.appendUInt32(16_000)
        data.appendUInt32(32_000)
        data.appendUInt16(2)
        data.appendUInt16(16)
        data.appendUInt16(22)
        data.appendUInt16(16)
        data.appendUInt32(0x4)
        data.appendUInt32(1)
        data.appendUInt16(0)
        data.appendUInt16(0x10)
        data.append(contentsOf: [0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71])
        data.appendASCII("data")
        data.appendUInt32(UInt32(dataBytes))
        return data
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            data.appendUInt16(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
