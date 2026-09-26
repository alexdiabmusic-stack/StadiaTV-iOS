import Foundation
import Compression

/// Manually strips the gzip container and inflates the raw DEFLATE payload via
/// Apple's Compression framework. `URLSession` does not auto-decompress FotMob's
/// live-ticker file — it's served as a static `.gz` object (verified live
/// 2026-09-24: magic bytes `1f 8b`, `Content-Type: application/json` despite being
/// real gzip bytes, no `Content-Encoding` header) — HTTP transfer decompression
/// only triggers on that header, which FotMob never sends here.
nonisolated enum FotMobGZip {
    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b, data[data.startIndex + 2] == 0x08 else { return nil }
        let flags = data[data.startIndex + 3]
        var offset = data.startIndex + 10
        if flags & 0x04 != 0, offset + 2 <= data.endIndex { // FEXTRA
            let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { while offset < data.endIndex, data[offset] != 0 { offset += 1 }; offset += 1 } // FNAME
        if flags & 0x10 != 0 { while offset < data.endIndex, data[offset] != 0 { offset += 1 }; offset += 1 } // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < data.endIndex - 8 else { return nil }
        let payload = data.subdata(in: offset..<(data.endIndex - 8))
        // Gzip's trailer ends with a little-endian ISIZE: the original size mod 2^32.
        let trailer = Array(data.suffix(4))
        let originalSize = trailer.enumerated().reduce(0) { acc, item in acc | (Int(item.element) << (8 * item.offset)) }
        guard originalSize > 0, originalSize < 100_000_000 else { return nil }
        var destination = [UInt8](repeating: 0, count: originalSize)
        let decodedCount = payload.withUnsafeBytes { sourcePointer -> Int in
            guard let sourceBase = sourcePointer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return destination.withUnsafeMutableBufferPointer { destinationPointer -> Int in
                guard let destinationBase = destinationPointer.baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, originalSize, sourceBase, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedCount == originalSize else { return nil }
        return Data(destination)
    }
}
