import Foundation
import zlib

/// Decodes a PGA TOUR "Compressed" GraphQL `payload` field: base64 → gzip
/// (standard gzip-header stream, confirmed against the pgatourPY/pgatouR
/// reference implementations, which use Python's `gzip.decompress` / R's
/// `memDecompress(type = "gzip")` — this is a *different* window mode than
/// this app's F1 decoder, which unwraps SignalR's raw-deflate `.z` topics)
/// → UTF-8 → JSON → `PGAValue`.
///
/// Any failure at any step throws a `PGATourError` naming the failing step
/// rather than propagating a cryptic zlib/JSON error. Callers are expected to
/// keep their previously-decoded state on a thrown error rather than clearing
/// the Tournament Centre to empty.
nonisolated enum PGAPayloadDecoder {
    /// Matches this app's other compressed-payload decoders' safety ceiling.
    static func decode(_ base64Payload: String, limit: Int = 16 * 1024 * 1024) throws -> PGAValue {
        let data = try decodeToData(base64Payload, limit: limit)
        do {
            return try JSONDecoder().decode(PGAValue.self, from: data)
        } catch {
            #if DEBUG
            print("[PGA] payload JSON decode failed: \(error)")
            #endif
            throw PGATourError.decompression("invalid JSON after decompression")
        }
    }

    /// Exposed separately so tests can assert on the raw decompressed bytes
    /// without also depending on JSON parsing succeeding.
    static func decodeToData(_ base64Payload: String, limit: Int = 16 * 1024 * 1024) throws -> Data {
        guard !base64Payload.isEmpty else {
            throw PGATourError.decompression("empty payload")
        }
        guard let compressed = Data(base64Encoded: base64Payload), !compressed.isEmpty else {
            #if DEBUG
            print("[PGA] payload was not valid base64 (length \(base64Payload.count))")
            #endif
            throw PGATourError.decompression("invalid base64")
        }
        guard compressed.count <= limit else { throw PGATourError.oversizedPayload }

        var stream = z_stream()
        // 15 (MAX_WBITS) + 16 selects the gzip container format (header + CRC),
        // as opposed to F1CompressedPayloadDecoder's raw-deflate `-MAX_WBITS`.
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PGATourError.decompression("failed to initialize gzip stream")
        }
        defer { inflateEnd(&stream) }

        do {
            let output: Data = try compressed.withUnsafeBytes { bytes -> Data in
                stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                var result = Data()
                var chunk = [UInt8](repeating: 0, count: 32_768)
                var status: Int32 = Z_OK
                repeat {
                    let count = chunk.count
                    status = chunk.withUnsafeMutableBytes { buffer -> Int32 in
                        stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw PGATourError.decompression("gzip inflate failed (zlib status \(status))")
                    }
                    result.append(contentsOf: chunk.prefix(count - Int(stream.avail_out)))
                    guard result.count <= limit else { throw PGATourError.oversizedPayload }
                    if status != Z_STREAM_END && stream.avail_in == 0 && stream.avail_out > 0 {
                        throw PGATourError.decompression("gzip stream ended unexpectedly")
                    }
                } while status != Z_STREAM_END
                return result
            }
            return output
        } catch let error as PGATourError {
            #if DEBUG
            print("[PGA] gzip decompression failed: \(error)")
            #endif
            throw error
        } catch {
            throw PGATourError.decompression("\(error)")
        }
    }
}
