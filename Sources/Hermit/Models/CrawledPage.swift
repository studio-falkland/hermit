import Foundation

/// The result of crawling a single URL.
///
/// A `CrawledPage` records the outcome of one fetch during a crawl — the discovered
/// outbound links, the HTTP status, and any error that occurred. It does not contain
/// the full HTML body; use ``ScrapedPage`` (via ``Hermit/scrape(_:configure:)`` or
/// ``Hermit/crawlAndScrape(_:crawl:scrape:)``) for that.
///
/// If ``error`` is non-nil, ``statusCode`` and ``outboundLinks`` may be empty.
public struct CrawledPage: Sendable {
    /// The URL that was fetched.
    public let url: URL

    /// The link depth at which this page was discovered.
    ///
    /// The seed URL has depth `0`. Pages linked directly from the seed have depth `1`, and so on.
    public let depth: Int

    /// The HTTP response status code, or `nil` if the request failed before receiving a response.
    public let statusCode: Int?

    /// Normalised absolute URLs discovered in `<a href>` tags on this page.
    ///
    /// These are the candidates that will be added to the crawl frontier, subject to
    /// ``CrawlConfiguration`` rules (domain policy, filters, depth limit, etc.).
    public let outboundLinks: [URL]

    /// The date and time at which this page was fetched.
    public let crawledAt: Date

    /// The error that occurred during the fetch, or `nil` if the request succeeded.
    public let error: (any Error)?
}
