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

    /// The page was rejected by a ``CrawlFilter`` before being crawled.
    ///
    /// ``FilterContext`` carries the response data that was available at the time
    /// of rejection. Fields are populated only when the corresponding filter
    /// requirements triggered an HTTP request; URL-only filters produce an empty
    /// context.
    ///
    /// - Parameters:
    ///   - url: The URL that was rejected.
    ///   - filter: The name of the filter type that rejected the page.
    ///   - context: The response data available when the filter rejected the page.
    case filtered(URL, filter: String, context: FilterContext = .empty)
}

/// Response data captured at the moment a ``CrawlFilter`` rejected a page.
///
/// New fields can be added over time without changing the signature of
/// ``HermitError/filtered(_:filter:context:)``. Fields are populated only when
/// the rejecting filter had the corresponding ``FilterRequirements``; for
/// example, a URL-only filter produces an empty context.
public struct FilterContext: Sendable, Equatable {
    /// The HTTP status code of the response that was rejected, if one was fetched.
    public let statusCode: Int?

    /// The bare MIME type from the `Content-Type` response header, with any
    /// `;charset=…` or other parameters stripped.
    public let contentType: String?

    /// Creates a filter context.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code of the response, if any.
    ///   - contentType: The bare MIME type from the `Content-Type` header, if any.
    public init(statusCode: Int? = nil, contentType: String? = nil) {
        self.statusCode = statusCode
        self.contentType = contentType
    }

    /// A context with no information — used when a filter rejected a page before
    /// any HTTP request was issued.
    public static let empty = FilterContext()
}
