import Foundation
import SwiftSoup
import NIOHTTP1

/// The result of scraping a single page, including parsed HTML, optional Markdown, and metadata.
///
/// A `ScrapedPage` gives you multiple views of the same page:
/// - ``html``: the raw response body
/// - ``markdown``: a Markdown rendering of the body (when ``ScrapeConfiguration/outputMarkdown`` is `true`)
/// - ``metadata``: structured data extracted from `<head>` tags
/// - ``extractions``: named text values from ``ScrapeConfiguration/extractions`` selectors
///
/// For arbitrary CSS queries, call ``parseDocument()`` to obtain a fresh SwiftSoup `Document`.
/// Keep the returned document task-local and do not pass it across concurrency boundaries.
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

    // MARK: DOM access

    /// Parses the stored HTML and returns a fresh SwiftSoup `Document`.
    ///
    /// Each call performs a full SwiftSoup parse of ``html``. For multiple queries on the
    /// same page, call this once, store the result in a local variable, and reuse it. Do
    /// not pass the returned `Document` across concurrency boundaries — treat it as
    /// task-local.
    ///
    /// - Returns: A parsed `Document`.
    /// - Throws: A SwiftSoup error if the HTML cannot be parsed.
    public func parseDocument() throws -> Document {
        try HTMLParser.parse(html, url: url)
    }

    // MARK: Convenience queries

    /// Returns all elements matching the given CSS selector.
    ///
    /// - Parameter css: A CSS selector string (e.g. `"article p"`, `"h1, h2"`).
    /// - Returns: A SwiftSoup `Elements` collection.
    /// - Throws: A SwiftSoup error if the selector is invalid.
    public func select(_ css: String) throws -> Elements {
        try parseDocument().select(css)
    }

    /// Returns the trimmed text content of the first element matching the given CSS selector.
    ///
    /// - Parameter css: A CSS selector string.
    /// - Returns: The text content, or `nil` if no element matched.
    /// - Throws: A SwiftSoup error if the selector is invalid.
    public func text(at css: String) throws -> String? {
        try parseDocument().select(css).first()?.text()
    }

    /// Returns the value of an attribute on the first element matching the given CSS selector.
    ///
    /// - Parameters:
    ///   - attr: The attribute name (e.g. `"href"`, `"data-id"`).
    ///   - css: A CSS selector string.
    /// - Returns: The attribute value, or `nil` if the element or attribute was not found.
    /// - Throws: A SwiftSoup error if the selector is invalid.
    public func attribute(_ attr: String, at css: String) throws -> String? {
        try parseDocument().select(css).first()?.attr(attr)
    }
}
