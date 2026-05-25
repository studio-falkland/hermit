import AsyncHTTPClient
import Foundation
import Logging

private let logger = Logger(label: "Hermit")

/// The main entry point for all Hermit crawl and scrape operations.
///
/// `Hermit` owns the underlying `AsyncHTTPClient.HTTPClient` and its connection pool.
/// A single instance should be shared for the lifetime of your application or task.
///
/// ## Lifecycle
///
/// For scripts and one-off tasks, use the scoped ``withHermit(_:configuration:)`` entry point,
/// which shuts down the HTTP client automatically on exit:
///
/// ```swift
/// try await Hermit.withHermit { hermit in
///     let result = try await hermit.crawl("https://example.com")
/// }
/// ```
///
/// For long-lived server processes (Vapor, Hummingbird), create an instance manually and
/// call ``shutdown()`` as part of your application's teardown:
///
/// ```swift
/// let hermit = Hermit(eventLoopGroupProvider: .shared(app.eventLoopGroup))
/// // ... use hermit ...
/// try await hermit.shutdown()
/// ```
///
/// ## Crawling
///
/// ```swift
/// // Collect a full URL index
/// let result = try await hermit.crawl("https://docs.example.com") {
///     $0.maxDepth = 3
///     $0.maxPages = 500
///     $0.stayOnDomain = true
///     $0.blacklist = ["/tag/"]
/// }
///
/// // Stream pages as they are discovered
/// for try await page in hermit.crawlStream("https://example.com") {
///     print(page.url)
/// }
/// ```
///
/// ## Scraping
///
/// ```swift
/// // Single page
/// let page = try await hermit.scrape("https://example.com/article") {
///     $0.outputMarkdown = true
///     $0.markdown.ignoreNav = true
/// }
///
/// // Batch — results arrive as each finishes
/// for try await page in hermit.scrapeStream(urls) {
///     save(page)
/// }
/// ```
public final class Hermit: Sendable {
    /// The shared AsyncHTTPClient instance. Owned here; never created elsewhere.
    private let httpClient: HTTPClient

    /// Post-processing steps applied to every ``ScrapedPage``, in order.
    private let processors: [any PageProcessor]

    /// The converter used to render HTML as Markdown when requested.
    private let markdownConverter: any MarkdownConverter

    // MARK: Lifecycle

    /// Creates a `Hermit` instance, runs `body`, then shuts down the HTTP client.
    ///
    /// This is the preferred entry point for scripts and CLI tools. The HTTP client is shut
    /// down whether `body` succeeds or throws, so connections are never leaked.
    ///
    /// - Parameters:
    ///   - configuration: Connection pool and decompression settings.
    ///   - body: An async closure that receives the configured `Hermit` instance.
    /// - Throws: Rethrows any error from `body`. Shutdown errors are swallowed so the
    ///   original error is always the one that propagates.
    public static func withHermit(
        configuration: HermitConfiguration = .default,
        _ body: (Hermit) async throws -> Void
    ) async throws {
        let hermit = Hermit(configuration: configuration)
        do {
            logger.debug("Session starting")
            try await body(hermit)
            try await hermit.httpClient.shutdown()
            logger.debug("Session ended cleanly")
        } catch {
            // Attempt graceful shutdown even on failure; ignore shutdown errors so the
            // original error from body() is the one that surfaces to the caller.
            try? await hermit.httpClient.shutdown()
            logger.debug("Session ended after error", metadata: ["error": "\(error)"])
            throw error
        }
    }

    /// Creates a `Hermit` instance.
    ///
    /// - Parameters:
    ///   - configuration: Connection pool and decompression settings. Defaults to ``HermitConfiguration/default``.
    ///   - eventLoopGroupProvider: Controls the underlying NIO event loop group.
    ///     Use `.singleton` (the default) for scripts and tools. Use `.shared(group)` to
    ///     share an existing group with a server framework like Vapor or Hummingbird.
    ///   - processors: An ordered list of ``PageProcessor`` implementations run on every scraped page.
    ///   - markdownConverter: A custom ``MarkdownConverter`` implementation.
    ///     Defaults to ``DefaultMarkdownConverter``.
    public init(
        configuration: HermitConfiguration = .default,
        eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .singleton,
        processors: [any PageProcessor] = [],
        markdownConverter: (any MarkdownConverter)? = nil
    ) {
        self.processors = processors
        self.markdownConverter = markdownConverter ?? DefaultMarkdownConverter()
        self.httpClient = HTTPClient(
            eventLoopGroupProvider: eventLoopGroupProvider,
            configuration: configuration.httpClientConfiguration
        )
    }

    /// Shuts down the HTTP client and releases its connection pool.
    ///
    /// Call this when managing the lifecycle manually (i.e. you did not use ``withHermit(_:configuration:)``).
    /// After calling `shutdown()`, this instance must not be used again.
    public func shutdown() async throws {
        try await httpClient.shutdown()
    }

    // MARK: Crawl

    /// Crawls a website and returns a complete ``CrawlResult`` when finished.
    ///
    /// This is a convenience wrapper around ``crawlStream(_:configure:)`` that collects all
    /// pages into a single result value. For large sites, prefer the stream variant to avoid
    /// accumulating all results in memory at once.
    ///
    /// - Parameters:
    ///   - url: The seed URL from which the crawl begins.
    ///   - configure: A closure to customise ``CrawlConfiguration`` before the crawl starts.
    /// - Returns: A ``CrawlResult`` containing all discovered pages and timing information.
    /// - Throws: ``HermitError`` if the crawl cannot be started.
    public func crawl(
        _ url: URL,
        configure: (inout CrawlConfiguration) -> Void = { _ in }
    ) async throws -> CrawlResult {
        var config = CrawlConfiguration.default
        configure(&config)
        let start = Date()
        var pages: [CrawledPage] = []
        var failed: [URL: any Error] = [:]
        // Drain the stream, separating successful fetches from failures.
        for try await page in crawlStream(url, configure: { $0 = config }) {
            if let error = page.error { failed[page.url] = error }
            else { pages.append(page) }
        }
        return CrawlResult(
            seedURL: url,
            pages: pages,
            failed: failed,
            duration: Date().timeIntervalSince(start)
        )
    }

    /// Crawls a website and streams ``CrawledPage`` values as they are discovered.
    ///
    /// Pages arrive in completion order (not BFS order) and the stream ends when the frontier
    /// is exhausted or ``CrawlConfiguration/maxPages`` is reached.
    ///
    /// ```swift
    /// for try await page in hermit.crawlStream("https://example.com") {
    ///     print("[\(page.depth)] \(page.url)")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The seed URL.
    ///   - configure: A closure to customise ``CrawlConfiguration``.
    /// - Returns: An `AsyncThrowingStream` of ``CrawledPage`` values.
    public func crawlStream(
        _ url: URL,
        configure: (inout CrawlConfiguration) -> Void = { _ in }
    ) -> AsyncThrowingStream<CrawledPage, Error> {
        var config = CrawlConfiguration.default
        configure(&config)
        // Build the rate limiter only if a limit was set; nil means no throttling.
        let rateLimiter = config.requestsPerSecond.map { RateLimiter(requestsPerSecond: $0) }
        let crawler = Crawler(
            httpClient: HermitHTTPClient(client: httpClient, config: config.network),
            rateLimiter: rateLimiter
        )
        logger.debug("Starting crawl stream", metadata: ["seed": "\(url)", "maxDepth": "\(config.maxDepth)", "maxPages": "\(config.maxPages == .max ? "unlimited" : "\(config.maxPages)")", "concurrency": "\(config.concurrency)"])
        return crawler.crawlStream(seed: url, configuration: config)
    }

    // MARK: Scrape

    /// Fetches and parses a single page.
    ///
    /// ```swift
    /// let page = try await hermit.scrape("https://example.com/article") {
    ///     $0.outputMarkdown = true
    ///     $0.markdown.ignoreNav = true
    ///     $0.extractions = ["author": ".byline"]
    /// }
    /// print(page.markdown!)
    /// ```
    ///
    /// - Parameters:
    ///   - url: The URL to fetch and parse.
    ///   - configure: A closure to customise ``ScrapeConfiguration``.
    /// - Returns: A ``ScrapedPage`` with HTML, optional Markdown, metadata, and extractions.
    /// - Throws: ``HermitError`` if the request or parsing fails.
    public func scrape(
        _ url: URL,
        configure: (inout ScrapeConfiguration) -> Void = { _ in }
    ) async throws -> ScrapedPage {
        var config = ScrapeConfiguration.default
        configure(&config)
        let scraper = Scraper(
            httpClient: HermitHTTPClient(client: httpClient, config: config.network),
            // Single-page scrapes are not rate-limited by default.
            rateLimiter: nil,
            markdownConverter: markdownConverter,
            processors: processors
        )
        logger.debug("Scraping single page", metadata: ["url": "\(url)"])
        return try await scraper.scrape(url, configuration: config)
    }

    /// Scrapes a collection of URLs concurrently and streams results as they complete.
    ///
    /// All URLs are dispatched at once. Results arrive in completion order, not input order.
    ///
    /// ```swift
    /// for try await page in hermit.scrapeStream(result.visitedURLs) {
    ///     save(page)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - urls: The URLs to scrape.
    ///   - configure: A closure to customise ``ScrapeConfiguration``.
    /// - Returns: An `AsyncThrowingStream` of ``ScrapedPage`` values.
    public func scrapeStream(
        _ urls: some Collection<URL> & Sendable,
        configure: (inout ScrapeConfiguration) -> Void = { _ in }
    ) -> AsyncThrowingStream<ScrapedPage, Error> {
        var config = ScrapeConfiguration.default
        configure(&config)
        let scraper = Scraper(
            httpClient: HermitHTTPClient(client: httpClient, config: config.network),
            rateLimiter: nil,
            markdownConverter: markdownConverter,
            processors: processors
        )
        logger.debug("Starting scrape stream", metadata: ["urlCount": "\(urls.count)"])
        return scraper.scrapeStream(urls: urls, configuration: config)
    }

    // MARK: Combined

    /// Crawls a site and scrapes every discovered page, streaming results as they complete.
    ///
    /// The crawl phase runs to completion first, building the full URL list. All discovered
    /// pages are then scraped concurrently, with results streamed as each finishes.
    ///
    /// ```swift
    /// for try await page in hermit.crawlAndScrape(
    ///     "https://docs.example.com",
    ///     crawl: { $0.maxDepth = 3; $0.whitelist = ["/docs/"] },
    ///     scrape: { $0.outputMarkdown = true }
    /// ) {
    ///     index(url: page.url, content: page.markdown)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The seed URL for the crawl phase.
    ///   - configureCrawl: A closure to customise ``CrawlConfiguration``.
    ///   - configureScrape: A closure to customise ``ScrapeConfiguration``.
    /// - Returns: An `AsyncThrowingStream` of ``ScrapedPage`` values.
    public func crawlAndScrape(
        _ url: URL,
        crawl configureCrawl: (inout CrawlConfiguration) -> Void = { _ in },
        scrape configureScrape: (inout ScrapeConfiguration) -> Void = { _ in }
    ) -> AsyncThrowingStream<ScrapedPage, Error> {
        var crawlConfig = CrawlConfiguration.default
        configureCrawl(&crawlConfig)
        var scrapeConfig = ScrapeConfiguration.default
        configureScrape(&scrapeConfig)

        let rateLimiter = crawlConfig.requestsPerSecond.map { RateLimiter(requestsPerSecond: $0) }
        let crawler = Crawler(
            httpClient: HermitHTTPClient(client: httpClient, config: crawlConfig.network),
            rateLimiter: rateLimiter
        )
        let scraper = Scraper(
            httpClient: HermitHTTPClient(client: httpClient, config: scrapeConfig.network),
            // Share the rate limiter so crawl and scrape requests are throttled together.
            rateLimiter: rateLimiter,
            markdownConverter: markdownConverter,
            processors: processors
        )

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Phase 1: crawl all pages to build the complete URL list.
                    logger.debug("crawlAndScrape phase 1: crawling", metadata: ["seed": "\(url)"])
                    let crawled = try await self.collectCrawl(crawler: crawler, seed: url, config: crawlConfig)
                    // Phase 2: scrape all discovered pages concurrently, yielding as each finishes.
                    logger.debug("crawlAndScrape phase 2: scraping", metadata: ["pageCount": "\(crawled.count)"])
                    try await withThrowingTaskGroup(of: ScrapedPage.self) { group in
                        for page in crawled {
                            group.addTask { try await scraper.scrape(page.url, configuration: scrapeConfig) }
                        }
                        for try await scraped in group {
                            continuation.yield(scraped)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Runs a full crawl and collects only the successfully fetched pages into an array.
    ///
    /// Used by ``crawlAndScrape(_:crawl:scrape:)`` to materialise the URL list before
    /// starting the scrape phase.
    private func collectCrawl(
        crawler: Crawler,
        seed: URL,
        config: CrawlConfiguration
    ) async throws -> [CrawledPage] {
        var pages: [CrawledPage] = []
        for try await page in crawler.crawlStream(seed: seed, configuration: config) {
            if page.error == nil { pages.append(page) }
        }
        return pages
    }
}
