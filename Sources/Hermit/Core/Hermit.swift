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
/// let config = try CrawlConfiguration(maxDepth: 3, maxPages: 500, stayOnDomain: true)
/// let result = try await hermit.crawl("https://docs.example.com", configuration: config)
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
/// let config = ScrapeConfiguration(outputMarkdown: true)
/// let page = try await hermit.scrape("https://example.com/article", configuration: config)
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
    /// This is a convenience wrapper around ``crawlStream(_:configuration:)`` that collects all
    /// pages into a single result value. For large sites, prefer the stream variant to avoid
    /// accumulating all results in memory at once.
    ///
    /// - Parameters:
    ///   - url: The seed URL from which the crawl begins.
    ///   - configuration: The crawl configuration. Defaults to ``CrawlConfiguration/default``.
    /// - Returns: A ``CrawlResult`` containing all discovered pages and timing information.
    /// - Throws: ``HermitError`` if the crawl cannot be started.
    public func crawl(
        _ url: URL,
        configuration: CrawlConfiguration = .default
    ) async throws -> CrawlResult {
        let start = Date()
        var pages: [CrawledPage] = []
        var failed: [URL: any Error] = [:]
        // Drain the stream, separating successful fetches from failures.
        for try await page in crawlStream(url, configuration: configuration) {
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
    ///   - configuration: The crawl configuration. Defaults to ``CrawlConfiguration/default``.
    /// - Returns: An `AsyncThrowingStream` of ``CrawledPage`` values.
    public func crawlStream(
        _ url: URL,
        configuration: CrawlConfiguration = .default
    ) -> AsyncThrowingStream<CrawledPage, Error> {
        // Build the rate limiter only if a limit was set; nil means no throttling.
        let rateLimiter = configuration.requestsPerSecond.map { RateLimiter(requestsPerSecond: $0) }
        let crawler = Crawler(
            httpClient: HermitHTTPClient(client: httpClient, config: configuration.network),
            rateLimiter: rateLimiter,
            filters: configuration.filters
        )
        logger.debug("Starting crawl stream", metadata: ["seed": "\(url)", "maxDepth": "\(configuration.maxDepth)", "maxPages": "\(configuration.maxPages == .max ? "unlimited" : "\(configuration.maxPages)")", "concurrency": "\(configuration.concurrency)"])
        return crawler.crawlStream(seed: url, configuration: configuration)
    }

    // MARK: Scrape

    /// Fetches and parses a single page.
    ///
    /// ```swift
    /// let config = ScrapeConfiguration(
    ///     outputMarkdown: true,
    ///     extractions: ["author": ".byline"]
    /// )
    /// let page = try await hermit.scrape("https://example.com/article", configuration: config)
    /// print(page.markdown!)
    /// ```
    ///
    /// - Parameters:
    ///   - url: The URL to fetch and parse.
    ///   - configuration: The scrape configuration. Defaults to ``ScrapeConfiguration/default``.
    /// - Returns: A ``ScrapedPage`` with HTML, optional Markdown, metadata, and extractions.
    /// - Throws: ``HermitError`` if the request or parsing fails.
    public func scrape(
        _ url: URL,
        configuration: ScrapeConfiguration = .default
    ) async throws -> ScrapedPage {
        let scraper = Scraper(
            httpClient: HermitHTTPClient(client: httpClient, config: configuration.network),
            // Single-page scrapes are not rate-limited by default.
            rateLimiter: nil,
            markdownConverter: markdownConverter,
            processors: processors
        )
        logger.debug("Scraping single page", metadata: ["url": "\(url)"])
        return try await scraper.scrape(url, configuration: configuration)
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
    ///   - configuration: The scrape configuration. Defaults to ``ScrapeConfiguration/default``.
    /// - Returns: An `AsyncThrowingStream` of ``ScrapedPage`` values.
    public func scrapeStream(
        _ urls: some Collection<URL> & Sendable,
        configuration: ScrapeConfiguration = .default
    ) -> AsyncThrowingStream<ScrapedPage, Error> {
        let scraper = Scraper(
            httpClient: HermitHTTPClient(client: httpClient, config: configuration.network),
            rateLimiter: nil,
            markdownConverter: markdownConverter,
            processors: processors
        )
        logger.debug("Starting scrape stream", metadata: ["urlCount": "\(urls.count)"])
        return scraper.scrapeStream(urls: urls, configuration: configuration)
    }

    // MARK: Combined

    /// Crawls a site and scrapes every discovered page, streaming results as they complete.
    ///
    /// The crawl phase runs to completion first, building the full URL list. All discovered
    /// pages are then scraped concurrently, with results streamed as each finishes.
    ///
    /// ```swift
    /// let crawlConfig = try CrawlConfiguration(maxDepth: 3, allowlist: ["/docs/"])
    /// let scrapeConfig = ScrapeConfiguration(outputMarkdown: true)
    /// for try await page in hermit.crawlAndScrape(
    ///     "https://docs.example.com",
    ///     crawl: crawlConfig,
    ///     scrape: scrapeConfig
    /// ) {
    ///     index(url: page.url, content: page.markdown)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The seed URL for the crawl phase.
    ///   - configuration: The crawl configuration for Phase 1.
    ///   - scrapeConfiguration: The scrape configuration for Phase 2.
    ///   - onCrawlFailure: A closure called for each page that failed during the crawl phase.
    ///     Defaults to `nil` (failures are logged at debug level).
    /// - Returns: An `AsyncThrowingStream` of ``ScrapedPage`` values.
    public func crawlAndScrape(
        _ url: URL,
        configuration: CrawlConfiguration = .default,
        scrapeConfiguration: ScrapeConfiguration = .default,
        onCrawlFailure: (@Sendable (CrawledPage) -> Void)? = nil
    ) -> AsyncThrowingStream<ScrapedPage, Error> {
        let rateLimiter = configuration.requestsPerSecond.map { RateLimiter(requestsPerSecond: $0) }
        let crawler = Crawler(
            httpClient: HermitHTTPClient(client: httpClient, config: configuration.network),
            rateLimiter: rateLimiter,
            captureHTML: true,
            filters: configuration.filters
        )
        let scraper = Scraper(
            httpClient: HermitHTTPClient(client: httpClient, config: scrapeConfiguration.network),
            // Share the rate limiter so crawl and scrape requests are throttled together.
            rateLimiter: rateLimiter,
            markdownConverter: markdownConverter,
            processors: processors
        )

        let onCrawlFailure = onCrawlFailure  // explicit sendable capture

        return AsyncThrowingStream { continuation in
            Task { [configuration, scrapeConfiguration, onCrawlFailure] in
                do {
                    // Phase 1: crawl all pages to build the complete URL list.
                    logger.debug("crawlAndScrape phase 1: crawling", metadata: ["seed": "\(url)"])
                    let crawled = try await self.collectCrawl(
                        crawler: crawler,
                        seed: url,
                        config: configuration,
                        onFailure: onCrawlFailure
                    )
                    // Phase 2: scrape all discovered pages concurrently, yielding as each finishes.
                    logger.debug("crawlAndScrape phase 2: scraping", metadata: ["pageCount": "\(crawled.count)"])
                    try await withThrowingTaskGroup(of: ScrapedPage.self) { group in
                        for page in crawled {
                            if let html = page.html, let statusCode = page.statusCode {
                                group.addTask { try await scraper.scrapeFromHTML(page.url, html: html, statusCode: statusCode, headers: page.responseHeaders, configuration: scrapeConfiguration) }
                            } else {
                                group.addTask { try await scraper.scrape(page.url, configuration: scrapeConfiguration) }
                            }
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
        config: CrawlConfiguration,
        onFailure: (@Sendable (CrawledPage) -> Void)?
    ) async throws -> [CrawledPage] {
        var pages: [CrawledPage] = []
        for try await page in crawler.crawlStream(seed: seed, configuration: config) {
            if let error = page.error {
                logger.debug("Crawl page failed, skipping scrape", metadata: ["url": "\(page.url)", "error": "\(error)"])
                onFailure?(page)
            } else {
                pages.append(page)
            }
        }
        return pages
    }
}