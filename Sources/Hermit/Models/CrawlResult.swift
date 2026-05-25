import Foundation

/// The aggregate result of a completed crawl operation.
///
/// Returned by ``Hermit/crawl(_:configure:)`` once the crawl finishes. For large sites,
/// prefer ``Hermit/crawlStream(_:configure:)`` to receive pages incrementally.
public struct CrawlResult: Sendable {
    /// The URL from which the crawl was seeded.
    public let seedURL: URL

    /// All pages that were successfully fetched, in the order they completed.
    public let pages: [CrawledPage]

    /// Pages that failed to fetch, keyed by their URL.
    public let failed: [URL: any Error]

    /// The total wall-clock time elapsed from start to finish, in seconds.
    public let duration: TimeInterval

    /// The URLs of all successfully fetched pages.
    public var visitedURLs: [URL] { pages.map(\.url) }

    /// Successfully fetched pages with no error recorded.
    public var succeeded: [CrawledPage] { pages.filter { $0.error == nil } }
}
