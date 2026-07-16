import Foundation
import NIOHTTP1

/// The result of scraping a single page, including parsed HTML, optional Markdown, and metadata.
///
/// A `ScrapedPage` is a pure value type containing the fetched URL, the raw HTML string,
/// an optional Markdown rendering, structured metadata, and any named CSS extractions.
///
/// ``ScrapedPage`` deliberately does not expose a parsed `SwiftSoup.Document`. The DOM is
/// only safe to touch on the task that created it — the parser mutates per-element state
/// during queries and the tree is not safe to share across concurrency boundaries. To run
/// custom DOM queries, implement a ``PageProcessor`` and access the document there; return
/// any extracted values as strings on the returned ``ScrapedPage``.
public struct ScrapedPage: Sendable {
    /// The URL that was fetched.
    public let url: URL

    /// The HTTP response status code.
    public let statusCode: Int

    /// The raw UTF-8 HTML body of the response.
    public let html: String

    /// A Markdown rendering of the page body, or `nil` if ``ScrapeConfiguration/outputMarkdown`` was `false`.
    public let markdown: String?

    /// Structured metadata extracted from the page's `<head>`.
    public let metadata: PageMetadata

    /// Results of the named CSS extractions defined in ``ScrapeConfiguration/extractions``.
    ///
    /// Each key is a name you chose; each value is the trimmed text content of the first
    /// matching element, or absent if no element matched.
    public let extractions: [String: String]

    /// Response HTTP headers from the server.
    ///
    /// The underlying ``NIOHTTP1/HTTPHeaders`` type is case-insensitive to match HTTP semantics.
    /// Look up values with ``NIOHTTP1/HTTPHeaders/first(name:)`` or the subscript.
    public let responseHeaders: HTTPHeaders
}
