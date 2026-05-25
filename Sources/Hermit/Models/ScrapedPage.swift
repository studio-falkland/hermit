import Foundation
import SwiftSoup

/// The result of scraping a single page, including parsed HTML, optional Markdown, and metadata.
///
/// A `ScrapedPage` gives you multiple views of the same page:
/// - ``html``: the raw response body
/// - ``document``: the live SwiftSoup DOM, for arbitrary CSS queries
/// - ``markdown``: a Markdown rendering of the body (when ``ScrapeConfiguration/outputMarkdown`` is `true`)
/// - ``metadata``: structured data extracted from `<head>` tags
/// - ``extractions``: named text values from ``ScrapeConfiguration/extractions`` selectors
///
/// ## Sendability
///
/// `ScrapedPage` is `@unchecked Sendable` because `SwiftSoup.Document` is a reference type
/// that does not conform to `Sendable`. The document is treated as read-only after construction
/// and must not be mutated.
public struct ScrapedPage: @unchecked Sendable {
    /// The URL that was fetched.
    public let url: URL

    /// The HTTP response status code.
    public let statusCode: Int

    /// The raw UTF-8 HTML body of the response.
    public let html: String

    /// The parsed SwiftSoup document.
    ///
    /// Use this for any CSS query that is not covered by the built-in helpers.
    /// Do not mutate this document after construction.
    public let document: Document

    /// A Markdown rendering of the page body, or `nil` if ``ScrapeConfiguration/outputMarkdown`` was `false`.
    public let markdown: String?

    /// Structured metadata extracted from the page's `<head>`.
    public let metadata: PageMetadata

    /// Results of the named CSS extractions defined in ``ScrapeConfiguration/extractions``.
    ///
    /// Each key is a name you chose; each value is the trimmed text content of the first
    /// matching element, or absent if no element matched.
    public let extractions: [String: String]

    // MARK: Convenience queries

    /// Returns all elements matching the given CSS selector.
    ///
    /// - Parameter css: A CSS selector string (e.g. `"article p"`, `"h1, h2"`).
    /// - Returns: A SwiftSoup `Elements` collection.
    /// - Throws: A SwiftSoup error if the selector is invalid.
    public func select(_ css: String) throws -> Elements {
        try document.select(css)
    }

    /// Returns the trimmed text content of the first element matching the given CSS selector.
    ///
    /// - Parameter css: A CSS selector string.
    /// - Returns: The text content, or `nil` if no element matched.
    /// - Throws: A SwiftSoup error if the selector is invalid.
    public func text(at css: String) throws -> String? {
        try document.select(css).first()?.text()
    }

    /// Returns the value of an attribute on the first element matching the given CSS selector.
    ///
    /// - Parameters:
    ///   - attr: The attribute name (e.g. `"href"`, `"data-id"`).
    ///   - css: A CSS selector string.
    /// - Returns: The attribute value, or `nil` if the element or attribute was not found.
    /// - Throws: A SwiftSoup error if the selector is invalid.
    public func attribute(_ attr: String, at css: String) throws -> String? {
        try document.select(css).first()?.attr(attr)
    }
}
