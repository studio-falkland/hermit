import AsyncHTTPClient
import Foundation
import NIOCore

/// A ``CrawlFilter`` that rejects responses whose body is not text-like, identified
/// by inspecting the first few bytes (a "magic number" sniff).
///
/// This filter is the last line of defense against the kind of failure mode that
/// occurs when a server's `Content-Type` header is missing, lying, or otherwise
/// insufficient to identify the resource. Specifically, it guards against the
/// SwiftSoup HTML parser being fed arbitrary binary data such as a PDF, which can
/// crash the process. The complementary ``ContentTypeFilter`` inspects headers
/// only; this one inspects the bytes themselves.
///
/// ```swift
/// hermit.crawl("https://example.com") {
///     $0.filters = [
///         ContentTypeFilter(),
///         BinaryContentFilter(),
///         StatusCodeFilter(),
///     ]
/// }
/// ```
///
/// ## Why `.body` and not `.headers`
///
/// Declaring ``requirements/.body`` forces the crawler into its GET-reuse branch:
/// the body collected for this filter is the same buffer that will be handed to
/// link extraction. That makes it impossible for the bytes to be parsed twice
/// and guarantees ``HTMLParser/extractLinks(from:base:)`` never sees a body that
/// has not been sniffed first.
public struct BinaryContentFilter: CrawlFilter {
    /// The number of leading bytes inspected from the body. Set to the largest
    /// signature end offset (8 bytes) plus signature length (4 bytes) plus
    /// comfortable headroom for the NUL-byte fallback heuristic.
    static let sniffLength: Int = 256

    public var requirements: FilterRequirements { .body }

    /// Creates a binary-content filter.
    public init() {}

    public func allow(_ response: HTTPClient.Response) async throws -> FilterDecision {
        // No body or a trivially short body is not something we can classify;
        // pass it through and let other filters (or the parser) decide.
        guard let body = response.body, body.readableBytes >= 4 else { return .allow }

        // Copy the first `sniffLength` bytes into a contiguous buffer so we
        // can do simple byte comparisons without wrestling with the buffer's
        // internal reader/writer indices.
        let length = min(Self.sniffLength, body.readableBytes)
        guard let head = body.getBytes(at: body.readerIndex, length: length) else {
            // Should not happen for a `ByteBuffer` we just checked the size of,
            // but be defensive: an unreadable body is not something to crash on.
            return .allow
        }

        if Self.looksBinary(head) { return .reject }
        return .allow
    }

    /// Returns `true` if `bytes` matches a known binary signature, or contains
    /// a NUL byte within the inspected window (a strong indicator of non-text).
    ///
    /// The signature table is deliberately small. A web crawler only needs to
    /// catch the file types a misconfigured server is likely to hand back when
    /// it forgets to set `Content-Type` correctly; comprehensive format
    /// detection is the responsibility of the consumer, not the crawler.
    private static func looksBinary(_ bytes: [UInt8]) -> Bool {
        for (offset, signature) in Self.signatures {
            let end = offset + signature.count
            guard end <= bytes.count else { continue }
            if Array(bytes[offset..<end]) == signature {
                return true
            }
        }
        // NUL byte heuristic. A genuine `0x00` is exceedingly rare in HTML
        // (browsers tolerate it but it almost never appears in real pages),
        // while it is common in many binary formats that don't appear in the
        // signature table above.
        return bytes.contains(0x00)
    }

    /// Known binary signatures, each as `(offset, bytes)` where `bytes` must
    /// match the body at `offset`. Container formats with variable headers
    /// (ISO BMFF, RIFF) are matched by their container signature alone — we
    /// don't enumerate subtypes like `mp42` vs `avif` because rejecting *any*
    /// container format as non-HTML is the correct behavior.
    ///
    /// Listed in roughly descending order of how often they appear in the wild.
    private static let signatures: [(offset: Int, bytes: [UInt8])] = [
        // %PDF-
        (0, [0x25, 0x50, 0x44, 0x46, 0x2D]),
        // PNG
        (0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        // JPEG (JFIF/Exif)
        (0, [0xFF, 0xD8, 0xFF]),
        // GIF87a / GIF89a
        (0, [0x47, 0x49, 0x46, 0x38]),
        // BMP
        (0, [0x42, 0x4D]),
        // RIFF container (WebP, WAV, AVI, etc. — covers any RIFF file as binary)
        (0, [0x52, 0x49, 0x46, 0x46]),
        // ISO BMFF `ftyp` box at offset 4 (variable size prefix; covers MP4,
        // MOV, M4V, HEIC, AVIF and any other ISO BMFF format)
        (4, [0x66, 0x74, 0x79, 0x70]),
        // Gzip
        (0, [0x1F, 0x8B]),
        // ZIP / Office (OOXML)
        (0, [0x50, 0x4B, 0x03, 0x04]),
        // Empty ZIP
        (0, [0x50, 0x4B, 0x05, 0x06]),
        // Spanned ZIP
        (0, [0x50, 0x4B, 0x07, 0x08]),
        // WOFF (Web Open Font Format)
        (0, [0x77, 0x4F, 0x46, 0x46]),
        // WOFF2 (Web Open Font Format 2)
        (0, [0x77, 0x4F, 0x46, 0x32]),
    ]
}
