import Foundation
import zlib

nonisolated enum F1CompressedPayloadDecoder {
    static func decode(_ base64: String, limit: Int = 16 * 1024 * 1024) throws -> F1Value {
        guard let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= limit else { throw F1LiveTimingError.decompression }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw F1LiveTimingError.decompression }
        defer { inflateEnd(&stream) }
        let output: Data = try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data(), chunk = [UInt8](repeating: 0, count: 32768)
            var status: Int32 = Z_OK
            repeat {
                let count = chunk.count
                status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw F1LiveTimingError.decompression }
                result.append(contentsOf: chunk.prefix(count - Int(stream.avail_out)))
                guard result.count <= limit else { throw F1LiveTimingError.oversizedPayload }
                if status != Z_STREAM_END && stream.avail_in == 0 && stream.avail_out > 0 { throw F1LiveTimingError.decompression }
            } while status != Z_STREAM_END
            return result
        }
        return try JSONDecoder().decode(F1Value.self, from: output)
    }
}
