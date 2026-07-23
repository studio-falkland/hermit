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
        let rateLimiter = configuration.requestsPerSecond.map { RateLimiter(requestsPerSecond: $0) }
        let httpClient = HermitHTTPClient(client: httpClient, config: configuration.network)

        logger.debug("Starting crawl stream", metadata: ["seed": "\(url)", "maxDepth": "\(configuration.maxDepth)", "maxPages": "\(configuration.maxPages == .max ? "unlimited" : "\(configuration.maxPages)")", "concurrency": "\(configuration.concurrency)"])

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let driver = CrawlDriver(
                        seed: url,
                        config: configuration,
                        httpClient: httpClient,
                        rateLimiter: rateLimiter
                    )
                    try await withThrowingTaskGroup(of: CrawledPage.self) { group in
                        // Initial burst: fill up to the configured concurrency limit.
                        for _ in 0..<Int(configuration.concurrency) {
                            guard case .fetch(let u, let d) = await driver.next() else { break }
                            group.addTask {
                                try await driver.rateLimiter?.acquire()
                                return await driver.fetchPage(url: u, depth: d)
                            }
                        }

                        // Drain loop: process one result, refill one task.
                        for try await page in group {
                            continuation.yield(page)
                            switch await driver.complete(page) {
                            case .fetch(let u, let d):
                                group.addTask {
                                    try await driver.rateLimiter?.acquire()
                                    return await driver.fetchPage(url: u, depth: d)
                                }
                            case .idle:
                                break
                            case .done:
                                group.cancelAll()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

    /// Crawls a site and scrapes every discovered page in a single merged pipeline.
    ///
    /// Crawl and scrape tasks share a single ``ThrowingTaskGroup``. As each page is
    /// crawled, it is immediately enqueued for scraping — there is no separate "collect
    /// all, then scrape all" phase. This means:
    ///
    /// - **Lower memory**: HTML bodies are held only until their scrape completes,
    ///   rather than accumulating every page before any scraping begins.
    /// - **Sooner first result**: The first ``ScrapedPage`` is yielded as soon as the
    ///   first page is crawled and scraped, not after the entire crawl finishes.
    /// - **Overlapped work**: CPU-bound parsing and markdown conversion overlap with
    ///   network-bound crawl fetches.
    ///
    /// Scrape concurrency is bounded to ``CrawlConfiguration/concurrency`` so that
    /// CPU-bound scrape work does not pile up unboundedly when crawling outpaces
    /// scraping. The shared rate limiter (when configured) governs the combined rate
    /// of crawl and scrape HTTP requests.
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
    ///   - url: The seed URL for the crawl.
    ///   - configuration: The crawl configuration.
    ///   - scrapeConfiguration: The scrape configuration.
    ///   - onCrawlFailure: A closure called for each page that failed during the crawl.
    ///     Defaults to `nil` (failures are logged at debug level).
    /// - Returns: An `AsyncThrowingStream` of ``ScrapedPage`` values.
    public func crawlAndScrape(
        _ url: URL,
        configuration: CrawlConfiguration = .default,
        scrapeConfiguration: ScrapeConfiguration = .default,
        onCrawlFailure: (@Sendable (CrawledPage) -> Void)? = nil
    ) -> AsyncThrowingStream<ScrapedPage, Error> {
        let rateLimiter = configuration.requestsPerSecond.map { RateLimiter(requestsPerSecond: $0) }
        let crawlHTTPClient = HermitHTTPClient(client: httpClient, config: configuration.network)
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
                    let crawlConfig = try CrawlConfiguration(
                        maxDepth: configuration.maxDepth,
                        maxPages: configuration.maxPages,
                        stayOnDomain: configuration.stayOnDomain,
                        includeSubdomains: configuration.includeSubdomains,
                        concurrency: configuration.concurrency,
                        requestsPerSecond: configuration.requestsPerSecond,
                        allowlist: configuration.allowlist,
                        denylist: configuration.denylist,
                        respectRobotsTxt: configuration.respectRobotsTxt,
                        filters: configuration.filters,
                        captureHTML: true,
                        network: configuration.network
                    )
                    let driver = CrawlDriver(
                        seed: url,
                        config: crawlConfig,
                        httpClient: crawlHTTPClient,
                        rateLimiter: rateLimiter
                    )
                    let concurrency = Int(configuration.concurrency)
                    let scrapeCap = concurrency  // bounded to the same concurrency as crawl

                    try await withThrowingTaskGroup(of: CrawlScrapeStep.self) { group in
                        // Seed initial crawl tasks.
                        for _ in 0..<concurrency {
                            guard case .fetch(let u, let d) = await driver.next() else { break }
                            group.addTask {
                                try await driver.rateLimiter?.acquire()
                                return .crawled(await driver.fetchPage(url: u, depth: d))
                            }
                        }

                        var pending: [CrawledPage] = []
                        var scrapeInFlight = 0
                        var crawlDone = false

                        // Helper to dispatch as many scrape tasks as the cap allows.
                        func dispatchScrapes() {
                            while scrapeInFlight < scrapeCap, !pending.isEmpty {
                                let page = pending.removeFirst()
                                scrapeInFlight += 1
                                group.addTask {
                                    if let html = page.html, let statusCode = page.statusCode {
                                        try await .scraped(scraper.scrapeFromHTML(page.url, html: html, statusCode: statusCode, headers: page.responseHeaders, configuration: scrapeConfiguration))
                                    } else {
                                        try await .scraped(scraper.scrape(page.url, configuration: scrapeConfiguration))
                                    }
                                }
                            }
                        }

                        for try await step in group {
                            switch step {
                            case .crawled(let page):
                                if let error = page.error {
                                    logger.debug("Crawl page failed, skipping scrape", metadata: ["url": "\(page.url)", "error": "\(error)"])
                                    onCrawlFailure?(page)
                                } else {
                                    pending.append(page)
                                }

                                // Refill: if the frontier has more work, add a crawl task.
                                if !crawlDone {
                                    switch await driver.complete(page) {
                                    case .fetch(let u, let d):
                                        group.addTask {
                                            try await driver.rateLimiter?.acquire()
                                            return .crawled(await driver.fetchPage(url: u, depth: d))
                                        }
                                    case .idle:
                                        break
                                    case .done:
                                        crawlDone = true
                                        // Do NOT cancel the group — scrape tasks may still be running.
                                    }
                                }

                                dispatchScrapes()

                            case .scraped(let scraped):
                                scrapeInFlight -= 1
                                continuation.yield(scraped)
                                dispatchScrapes()
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}