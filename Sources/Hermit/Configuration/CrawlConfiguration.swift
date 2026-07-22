/// Configuration for a crawl operation.
///
/// Pass an instance to ``Hermit/crawl(_:configure:)`` or ``Hermit/crawlStream(_:configure:)``
/// using the trailing closure syntax:
///
/// ```swift
/// let result = try await hermit.crawl("https://example.com") {
///     $0.maxDepth = 3
///     $0.maxPages = 500
///     $0.stayOnDomain = true
///     $0.concurrency = 16
///     $0.requestsPerSecond = 10
///     $0.denylist = ["/tag/", "/author/"]
/// }
/// ```
public struct CrawlConfiguration: Sendable {
    /// The maximum link depth to follow from the seed URL.
    ///
    /// The seed URL itself is depth `0`. Links found on the seed are depth `1`, and so on.
    /// Pages at a depth greater than `maxDepth` are never enqueued. Defaults to `3`.
    public var maxDepth: Int = 3

    /// The maximum total number of pages to visit across the entire crawl.
    ///
    /// Once this limit is reached, no new URLs are enqueued and the crawl finishes
    /// as soon as in-flight requests complete. Defaults to `.max` (unlimited).
    public var maxPages: Int = .max

    /// When `true`, only URLs on the same host as the seed URL are followed.
    ///
    /// Combined with ``includeSubdomains`` to control exact subdomain behaviour.
    /// Defaults to `true`.
    public var stayOnDomain: Bool = true

    /// When `true` and ``stayOnDomain`` is also `true`, URLs on subdomains of the
    /// seed host are also followed.
    ///
    /// For example, if the seed is `example.com`, enabling this will also crawl
    /// `docs.example.com` and `blog.example.com`. Defaults to `false`.
    public var includeSubdomains: Bool = false

    /// The maximum number of pages fetched simultaneously.
    ///
    /// Higher values increase throughput but also increase load on the target server.
    /// Defaults to `8`.
    public var concurrency: Int = 8

    /// The maximum number of HTTP requests per second across all concurrent workers.
    ///
    /// `nil` means no rate limit is applied. Defaults to `nil`.
    public var requestsPerSecond: Double? = nil

    /// URL patterns that restrict which pages are visited.
    ///
    /// When non-empty, a URL must match at least one allowlist pattern to be enqueued.
    /// Denylist rules take priority over allowlist rules. Defaults to `[]` (no restriction).
    public var allowlist: [URLPattern] = []

    /// URL patterns that prevent matching pages from being visited.
    ///
    /// A URL matching any denylist pattern is never enqueued, even if it also matches
    /// an allowlist pattern. Defaults to `[]` (nothing blocked).
    public var denylist: [URLPattern] = []

    /// When `true`, Hermit fetches and respects each host's `robots.txt` before crawling.
    ///
    /// Defaults to `true`.
    public var respectRobotsTxt: Bool = true

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
    public var filters: [any CrawlFilter] = [
        ContentTypeFilter(),
        BinaryContentFilter(),
        StatusCodeFilter(),
    ]

    /// HTTP-level settings such as user agent, timeout, and custom headers.
    public var network: NetworkConfiguration = .default

    /// The default crawl configuration.
    public static let `default` = CrawlConfiguration()
}
