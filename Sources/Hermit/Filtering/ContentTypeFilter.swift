import AsyncHTTPClient
import Foundation

/// A ``CrawlFilter`` that rejects pages whose `Content-Type` is not in an allowlist.
///
/// Defaults to allowing `text/html` and `application/xhtml+xml`, the two MIME types
/// a web crawler can meaningfully parse for links. Use this to avoid downloading
/// PDFs, images, archives, and other non-HTML resources linked from crawled pages.
///
/// ```swift
/// let filter = ContentTypeFilter(allowedTypes: ["text/html"])
/// ```
public struct ContentTypeFilter: CrawlFilter {
    /// The MIME types that are allowed to be crawled.
    public let allowedTypes: Set<String>

    public var requirements: FilterRequirements { .headers }

    /// Creates a content-type filter.
    ///
    /// - Parameter allowedTypes: The set of MIME types (without parameters) that
    ///   are allowed. Defaults to `["text/html", "application/xhtml+xml"]`.
    public init(allowedTypes: Set<String> = ["text/html", "application/xhtml+xml"]) {
        self.allowedTypes = allowedTypes
    }

    public func allow(_ response: HTTPClient.Response) async throws -> FilterDecision {
        guard let contentType = response.headers.first(name: "content-type") else {
            return .reject
        }
        let mimeType = contentType
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let mimeType else {
            return .reject
        }
        return allowedTypes.contains(mimeType) ? .allow : .reject
    }
}
