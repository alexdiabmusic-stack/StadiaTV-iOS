import Foundation
import Testing
@testable import BannerTV

@Suite("Gzip inflate")
struct GzipInflateTests {

    private static let body = Data(#"<tv><channel id="a"><display-name>A</display-name></channel></tv>"#.utf8)

    /// `gzip.compress(body, mtime=0)`.
    private static let valid = Data(base64Encoded: "H4sIAAAAAAACA7MpKbOzSc5IzMtLzVHITLFVSlSys0nJLC7ISazUzUvMTbVztNFH4dvoQ5UDWUDNAB4rK7JBAAAA")!
    /// The same file with its last ten bytes missing.
    private static let truncated = Data(base64Encoded: "H4sIAAAAAAACA7MpKbOzSc5IzMtLzVHITLFVSlSys0nJLC7ISazUzUvMTbVztNFH4dvoQ5UDWUA=")!
    /// The same file with one bit of the CRC-32 flipped.
    private static let corrupt = Data(base64Encoded: "H4sIAAAAAAACA7MpKbOzSc5IzMtLzVHITLFVSlSys0nJLC7ISazUzUvMTbVztNFH4dvoQ5UDWUDNAOErK7JBAAAA")!
    /// 100,000 × "x", which compresses to 132 bytes.
    private static let hundredThousandXs = Data(base64Encoded: "H4sIAAAAAAACA+3BMQEAAADCoNqLbw0PoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIBXA3ERB/6ghgEA")!

    @Test("A gzip file inflates to its original bytes")
    func inflates() {
        #expect(GzipInflate.decompress(Self.valid) == .inflated(Self.body))
    }

    @Test("A slice of a larger buffer inflates the same way")
    func inflatesASlice() {
        let padded = Data(repeating: 0xAA, count: 7) + Self.valid + Data(repeating: 0xBB, count: 3)
        let slice = padded[7..<(padded.count - 3)]
        #expect(GzipInflate.decompress(slice) == .inflated(Self.body))
    }

    @Test("Anything that isn't gzip is left for the caller to use as it is")
    func notGzip() {
        #expect(GzipInflate.decompress(Self.body) == .notGzip)
        #expect(GzipInflate.decompress(Data()) == .notGzip)
        #expect(GzipInflate.decompress(Data([0x1f])) == .notGzip)
    }

    @Test("A truncated or corrupt gzip file is refused, never half-returned")
    func broken() {
        #expect(GzipInflate.decompress(Self.truncated) == .failed)
        #expect(GzipInflate.decompress(Self.corrupt) == .failed)
        #expect(GzipInflate.decompress(Data([0x1f, 0x8b])) == .failed)
    }

    @Test("Output past the limit is refused")
    func limit() {
        #expect(GzipInflate.decompress(Self.hundredThousandXs, limit: 100_000) == .inflated(Data(repeating: UInt8(ascii: "x"), count: 100_000)))
        #expect(GzipInflate.decompress(Self.hundredThousandXs, limit: 99_999) == .failed)
        #expect(GzipInflate.decompress(Self.hundredThousandXs, limit: 1_000) == .failed)
    }
}
