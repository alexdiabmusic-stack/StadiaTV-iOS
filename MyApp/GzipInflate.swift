import Foundation
import zlib

/// Inflates a gzip file (RFC 1952) with the system zlib.
///
/// zlib reads the container itself (header flags, CRC-32, length trailer) and streams into a
/// growing buffer, so nothing here depends on the file's own size field. The Compression
/// framework's `COMPRESSION_ZLIB` is no substitute: it decodes bare DEFLATE with no framing at
/// all, so the container has to be parsed by hand and its CRC goes unchecked.
nonisolated enum GzipInflate {

    enum Outcome: Equatable {
        /// Not a gzip stream; callers use the bytes as they are.
        case notGzip
        case inflated(Data)
        /// Starts like gzip but is truncated, corrupt, or would expand past the limit.
        case failed
    }

    /// The largest guide this app will inflate. A feed is tens of megabytes compressed and
    /// 100 MB+ of XML; without a ceiling a corrupt or hostile one could expand until the app is
    /// killed for memory.
    static let maxInflatedBytes = 512 * 1_024 * 1_024

    /// DEFLATE cannot expand data by more than about 1032:1, so a trailer claiming more than that
    /// is not telling the truth about this stream.
    private static let maxExpansionRatio = 1_032

    static func decompress(_ data: Data, limit: Int = maxInflatedBytes) -> Outcome {
        let count = data.count
        guard count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return .notGzip }
        // zlib counts input in 32 bits.
        guard count <= Int(UInt32.max) else { return .failed }

        var stream = z_stream()
        // 15 (MAX_WBITS) + 16 selects the gzip container: header, DEFLATE payload, CRC-32 and length.
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return .failed
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        // The trailer's length field (modulo 2^32) saves the buffer regrowing on a big guide.
        if count >= 18 {
            let tail = [UInt8](data.suffix(4))
            let declared = Int(tail[0]) | Int(tail[1]) << 8 | Int(tail[2]) << 16 | Int(tail[3]) << 24
            if declared > 0, declared <= count * maxExpansionRatio {
                output.reserveCapacity(min(declared, limit))
            }
        }

        var chunk = [UInt8](repeating: 0, count: 1 << 20)
        let finished = data.withUnsafeBytes { raw -> Bool in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            while true {
                var status = Z_OK
                chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    let produced = buffer.count - Int(stream.avail_out)
                    if let base = buffer.baseAddress, produced > 0 { output.append(base, count: produced) }
                }
                guard status == Z_OK || status == Z_STREAM_END else { return false }
                guard output.count <= limit else { return false }
                if status == Z_STREAM_END { return true }
                // Input used up and room to spare, yet no end of stream: the file is cut short.
                if stream.avail_in == 0, stream.avail_out > 0 { return false }
            }
        }
        return finished ? .inflated(output) : .failed
    }
}
