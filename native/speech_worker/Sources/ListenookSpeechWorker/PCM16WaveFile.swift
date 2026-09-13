import Foundation

enum PCM16WaveFileError: Error, Equatable {
    case missing
    case invalid
}

/// Metadata and bounded range access for a 16-bit mono PCM WAVE file.
/// The audio data chunk is never materialized as one duration-sized array.
struct PCM16WaveFile: Sendable {
    let path: String
    let sampleRate: Int
    let dataOffset: UInt64
    let sampleCount: Int

    init(path: String) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw PCM16WaveFileError.missing
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        let header: Data
        do {
            fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            header = try Self.readExactly(handle, count: 12)
        } catch let error as PCM16WaveFileError {
            throw error
        } catch {
            throw PCM16WaveFileError.invalid
        }
        guard header.count == 12,
              Self.ascii(header, 0, 4) == "RIFF",
              Self.ascii(header, 8, 4) == "WAVE"
        else {
            throw PCM16WaveFileError.invalid
        }

        var format: UInt16?
        var channels: UInt16?
        var parsedSampleRate: UInt32?
        var bits: UInt16?
        var parsedDataOffset: UInt64?
        var dataByteCount: Int?
        var offset: UInt64 = 12

        while offset + 8 <= fileSize {
            do {
                try handle.seek(toOffset: offset)
                let chunkHeader = try Self.readExactly(handle, count: 8)
                let name = Self.ascii(chunkHeader, 0, 4)
                let size = UInt64(Self.readUInt32(chunkHeader, 4))
                let start = offset + 8
                let (end, overflow) = start.addingReportingOverflow(size)
                guard !overflow, end <= fileSize else {
                    throw PCM16WaveFileError.invalid
                }

                if name == "fmt " {
                    guard size >= 16 else {
                        throw PCM16WaveFileError.invalid
                    }
                    try handle.seek(toOffset: start)
                    let formatData = try Self.readExactly(
                        handle,
                        count: Int(min(size, 40))
                    )
                    format = Self.readUInt16(formatData, 0)
                    channels = Self.readUInt16(formatData, 2)
                    parsedSampleRate = Self.readUInt32(formatData, 4)
                    bits = Self.readUInt16(formatData, 14)
                    if format == 0xfffe {
                        guard formatData.count >= 40,
                              Self.readUInt32(formatData, 24) == 1
                        else {
                            throw PCM16WaveFileError.invalid
                        }
                        format = 1
                    }
                } else if name == "data" {
                    guard size <= UInt64(Int.max) else {
                        throw PCM16WaveFileError.invalid
                    }
                    parsedDataOffset = start
                    dataByteCount = Int(size)
                }

                if format != nil, parsedDataOffset != nil { break }
                let (next, paddingOverflow) = end.addingReportingOverflow(size & 1)
                guard !paddingOverflow, next <= fileSize else {
                    throw PCM16WaveFileError.invalid
                }
                offset = next
            } catch let error as PCM16WaveFileError {
                throw error
            } catch {
                throw PCM16WaveFileError.invalid
            }
        }

        guard format == 1,
              channels == 1,
              let parsedSampleRate,
              parsedSampleRate == 16_000,
              bits == 16,
              let parsedDataOffset,
              let dataByteCount,
              dataByteCount.isMultiple(of: 2)
        else {
            throw PCM16WaveFileError.invalid
        }

        self.path = path
        sampleRate = Int(parsedSampleRate)
        dataOffset = parsedDataOffset
        sampleCount = dataByteCount / 2
    }

    func readSamples(_ range: Range<Int>) throws -> [Float] {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= sampleCount
        else {
            throw PCM16WaveFileError.invalid
        }
        guard !range.isEmpty else { return [] }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw PCM16WaveFileError.missing
        }
        defer { try? handle.close() }

        let byteOffset = dataOffset + UInt64(range.lowerBound * 2)
        let byteCount = range.count * 2
        let data: Data
        do {
            try handle.seek(toOffset: byteOffset)
            data = try Self.readExactly(handle, count: byteCount)
        } catch let error as PCM16WaveFileError {
            throw error
        } catch {
            throw PCM16WaveFileError.invalid
        }

        var samples = [Float]()
        samples.reserveCapacity(range.count)
        var index = 0
        while index < data.count {
            let raw = Int16(bitPattern: Self.readUInt16(data, index))
            samples.append(Float(raw) / 32768)
            index += 2
        }
        return samples
    }

    private static func readExactly(
        _ handle: FileHandle,
        count: Int
    ) throws -> Data {
        guard count >= 0 else { throw PCM16WaveFileError.invalid }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count),
                  !chunk.isEmpty
            else {
                throw PCM16WaveFileError.invalid
            }
            data.append(chunk)
        }
        return data
    }

    private static func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
        guard offset >= 0, offset + count <= data.count else { return "" }
        return String(decoding: data[offset..<(offset + count)], as: UTF8.self)
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
