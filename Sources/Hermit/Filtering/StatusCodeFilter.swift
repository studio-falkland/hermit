import AsyncHTTPClient
import Foundation

/// A ``CrawlFilter`` that rejects pages whose HTTP status code is not in an allowlist.
///
/// Defaults to allowing all 2xx status codes. Use this to skip 4xx and 5xx error
/// pages that would otherwise be crawled and link-extracted despite being error
/// responses.
///
/// ```swift
/// let filter = StatusCodeFilter(allowedCodes: [200, 301, 302])
/// ```
public struct StatusCodeFilter: CrawlFilter {
    /// The status codes that are allowed to be crawled.
    public let allowedCodes: Set<Int>

    public var requirements: FilterRequirements { .headers }

    /// Creates a status-code filter.
    ///
    /// - Parameter allowedCodes: The set of HTTP status codes that are allowed.
    ///   Defaults to all 2xx codes.
    public init(allowedCodes: Set<Int> = Set(200..<300)) {
        self.allowedCodes = allowedCodes
    }

    public func allow(_ response: HTTPClient.Response) async throws -> FilterDecision {
        allowedCodes.contains(Int(response.status.code)) ? .allow : .reject
    }
}
