/// Configuration for a crawl operation.
///
/// Pass an instance to ``Hermit/crawl(_:configuration:)`` or ``Hermit/crawlStream(_:configuration:)``.
///
/// ```swift
/// let config = try CrawlConfiguration(maxDepth: 3, maxPages: 500, concurrency: 16)
/// let result = try await hermit.crawl("https://example.com", configuration: config)
/// ```
public struct CrawlConfiguration: Sendable {
    /// The maximum link depth to follow from the seed URL.
    ///
    /// The seed URL itself is depth `0`. Links found on the seed are depth `1`, and so on.
    /// Pages at a depth greater than `maxDepth` are never enqueued. Defaults to `3`.
    public let maxDepth: UInt

    /// The maximum total number of pages to visit across the entire crawl.
    ///
    /// Once this limit is reached, no new URLs are enqueued and the crawl finishes
    /// as soon as in-flight requests complete. Defaults to `.max` (unlimited).
    public let maxPages: UInt

    /// When `true`, only URLs on the same host as the seed URL are followed.
    ///
    /// Combined with ``includeSubdomains`` to control exact subdomain behaviour.
    /// Defaults to `true`.
    public let stayOnDomain: Bool

    /// When `true` and ``stayOnDomain`` is also `true`, URLs on subdomains of the
    /// seed host are also followed.
    ///
    /// For example, if the seed is `example.com`, enabling this will also crawl
    /// `docs.example.com` and `blog.example.com`. Defaults to `false`.
    public let includeSubdomains: Bool

    /// The maximum number of pages fetched simultaneously.
    ///
    /// Higher values increase throughput but also increase load on the target server.
    /// Defaults to `8`.
    public let concurrency: UInt

    /// The maximum number of HTTP requests per second across all concurrent workers.
    ///
    /// `nil` means no rate limit is applied. Defaults to `nil`.
    public let requestsPerSecond: Double?

    /// URL patterns that restrict which pages are visited.
    ///
    /// When non-empty, a URL must match at least one allowlist pattern to be enqueued.
    /// Denylist rules take priority over allowlist rules. Defaults to `[]` (no restriction).
    public let allowlist: [URLPattern]

    /// URL patterns that prevent matching pages from being visited.
    ///
    /// A URL matching any denylist pattern is never enqueued, even if it also matches
    /// an allowlist pattern. Defaults to `[]` (nothing blocked).
    public let denylist: [URLPattern]

    /// When `true`, Hermit fetches and respects each host's `robots.txt` before crawling.
    ///
    /// Defaults to `true`.
    public let respectRobotsTxt: Bool

    /// Response-level filters evaluated against each discovered page before it is crawled.
    ///
    /// Filters run after a URL has passed the URL-level ``allowlist``/``denylist`` and
    /// ``stayOnDomain`` checks, but before the full crawl GET is issued. Each filter
    /// declares its data requirements via ``CrawlFilter/requirements``; the crawler
    /// makes the minimal request needed to satisfy all filters (none, HEAD, or GET).
    ///
    /// Defaults to rejecting non-HTML content types and binary bodies.
    ///
    /// ```swift
    /// hermit.crawl("https://example.com") {
    ///     $0.filters = [
    ///         ContentTypeFilter(),
    ///         BinaryContentFilter(),
    ///         StatusCodeFilter(),
    ///     ]
    /// }
    /// ```
    public let filters: [any CrawlFilter]

    /// HTTP-level settings such as user agent, timeout, and custom headers.
    public let network: NetworkConfiguration

    /// Creates a crawl configuration.
    ///
    /// - Parameters:
    ///   - maxDepth: Maximum link depth to follow (default: `3`).
    ///   - maxPages: Maximum pages to visit (default: `.max`).
    ///   - stayOnDomain: Restrict to the seed host (default: `true`).
    ///   - includeSubdomains: Also crawl subdomains (default: `false`).
    ///   - concurrency: Concurrent fetches (default: `8`).
    ///   - requestsPerSecond: Rate limit, or `nil` for unlimited (default: `nil`).
    ///   - allowlist: URL patterns that restrict which pages are visited (default: `[]`).
    ///   - denylist: URL patterns that block matching pages (default: `[]`).
    ///   - respectRobotsTxt: Fetch and respect `robots.txt` (default: `true`).
    ///   - filters: Response-level filters (default: `[ContentTypeFilter(), BinaryContentFilter(), StatusCodeFilter()]`).
    ///   - network: HTTP-level settings (default: `.default`).
    /// - Throws: ``HermitError/invalidConfiguration(_:)`` if any value is invalid.
    public init(
        maxDepth: UInt = 3,
        maxPages: UInt = .max,
        stayOnDomain: Bool = true,
        includeSubdomains: Bool = false,
        concurrency: UInt = 8,
        requestsPerSecond: Double? = nil,
        allowlist: [URLPattern] = [],
        denylist: [URLPattern] = [],
        respectRobotsTxt: Bool = true,
        filters: [any CrawlFilter] = [
            ContentTypeFilter(),
            BinaryContentFilter(),
            StatusCodeFilter(),
        ],
        network: NetworkConfiguration = .default
    ) throws {
        guard concurrency > 0 else {
            throw HermitError.invalidConfiguration("concurrency must be greater than 0")
        }
        guard maxPages > 0 else {
            throw HermitError.invalidConfiguration("maxPages must be greater than 0")
        }
        if let rps = requestsPerSecond {
            guard rps > 0, rps.isFinite else {
                throw HermitError.invalidConfiguration("requestsPerSecond must be > 0 and finite")
            }
        }
        self.maxDepth = maxDepth
        self.maxPages = maxPages
        self.stayOnDomain = stayOnDomain
        self.includeSubdomains = includeSubdomains
        self.concurrency = concurrency
        self.requestsPerSecond = requestsPerSecond
        self.allowlist = allowlist
        self.denylist = denylist
        self.respectRobotsTxt = respectRobotsTxt
        self.filters = filters
        self.network = network
    }

    /// The default crawl configuration.
    ///
    /// All values are valid defaults — this never throws.
    public static let `default`: CrawlConfiguration = {
        // Force-unwrap is safe: all defaults are valid.
        try! CrawlConfiguration()
    }()
}