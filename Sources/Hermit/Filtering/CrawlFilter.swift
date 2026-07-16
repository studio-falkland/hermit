import AsyncHTTPClient
import Foundation

/// The result of evaluating a ``CrawlFilter`` against a discovered page.
public enum FilterDecision: Sendable {
    /// The page passes this filter and should be crawled.
    case allow
    /// The page is rejected by this filter and should be skipped.
    case reject
}

/// Declares how much response data a ``CrawlFilter`` needs to make a decision.
///
/// The levels are ordered: a higher level implies access to all lower-level data.
/// The crawler aggregates this across all configured filters and performs the
/// minimal request needed to satisfy the highest requirement.
///
/// - Seealso: ``CrawlFilter/requirements``
public enum FilterRequirements: Sendable, Comparable {
    /// The filter only inspects the URL. No HTTP request is needed.
    ///
    /// The response passed to ``CrawlFilter/allow(_:)`` will have `url` populated
    /// and all other fields empty or default.
    case url

    /// The filter inspects the status code and/or response headers.
    ///
    /// A HEAD request is issued. The response will have `url`, `status`, and `headers`
    /// populated; `body` will be `nil`.
    case headers

    /// The filter inspects the response body.
    ///
    /// A full GET request is issued. All response fields are populated. When a body
    /// filter passes, the GET response is reused for link extraction — no second
    /// request is made.
    case body
}

/// A plugin that inspects a discovered page's response to decide whether it
/// should be crawled.
///
/// Filters run **after** a URL has been enqueued (i.e. it has already passed
/// ``URLFilter`` and ``DomainPolicy``) but **before** the full crawl GET is
/// issued. This lets you cheaply reject non-HTML resources (PDFs, images),
/// error pages, or any other response characteristic.
///
/// Declare the minimum data your filter needs via ``requirements``. The crawler
/// batches filters by requirement level and runs them in order from cheapest
/// to most expensive, skipping later phases as soon as one filter rejects.
///
/// ```swift
/// struct FileExtensionFilter: CrawlFilter {
///     let blockedExtensions: Set<String>
///
///     var requirements: FilterRequirements { .url }
///
///     func allow(_ response: HTTPClient.Response) async -> FilterDecision {
///         guard let url = response.url else { return .allow }
///         let ext = url.pathExtension
///         return blockedExtensions.contains(ext) ? .reject : .allow
///     }
/// }
/// ```
public protocol CrawlFilter: Sendable {
    /// The level of response data this filter needs.
    ///
    /// The crawler aggregates this across all filters and performs the minimal
    /// request that satisfies the highest requirement.
    var requirements: FilterRequirements { get }

    /// Evaluate whether the page described by `response` should be crawled.
    ///
    /// The response is populated up to the level declared by ``requirements``.
    /// Fields beyond that level are empty or `nil` and must not be relied upon.
    ///
    /// - Parameter response: The response for the discovered URL. The amount of
    ///   data populated depends on this filter's ``requirements``.
    /// - Returns: `.allow` to proceed with the crawl, or `.reject` to skip the page.
    func allow(_ response: HTTPClient.Response) async -> FilterDecision
}
