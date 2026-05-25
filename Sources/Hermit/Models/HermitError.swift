import Foundation

/// The top-level error type for all Hermit operations.
///
/// All errors produced by Hermit crawl and scrape operations are surfaced as `HermitError`.
/// Underlying system or library errors are wrapped and preserved in the `.network` and
/// `.parsing` cases so callers can inspect the root cause if needed.
public enum HermitError: Error, Sendable {
    /// The provided URL string could not be parsed into a valid `URL`.
    case invalidURL(String)

    /// A network-level failure occurred while fetching the given URL.
    ///
    /// - Parameters:
    ///   - url: The URL that was being fetched when the error occurred.
    ///   - underlying: The original error thrown by the HTTP layer.
    case network(URL, underlying: any Error)

    /// The response body could not be parsed or decoded.
    ///
    /// - Parameters:
    ///   - url: The URL whose response body caused the error.
    ///   - underlying: The original parsing error.
    case parsing(URL, underlying: any Error)

    /// The request to the given URL was blocked by the site's `robots.txt` rules.
    case blockedByRobotsTxt(URL)

    /// The crawl was halted because ``CrawlConfiguration/maxPages`` was reached.
    case maxPagesReached

    /// The operation was cancelled before it could complete.
    case cancelled
}
