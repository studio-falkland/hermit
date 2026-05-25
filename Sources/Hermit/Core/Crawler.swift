import Foundation
import Logging

/// Drives the concurrent BFS crawl using a `ThrowingTaskGroup`.
///
/// `Crawler` owns the core fetch-and-refill loop:
/// 1. Seed the `TaskGroup` with up to `concurrency` tasks.
/// 2. As each task completes, yield the page and ask the ``CrawlFrontier`` for the next URL.
/// 3. If a URL is available, immediately add a new task to replace the one that finished.
/// 4. Stop when the frontier signals `.done`.
///
/// This keeps exactly `concurrency` tasks in-flight at all times without a semaphore,
/// and without ever blocking a thread.
private let logger = Logger(label: "Hermit.Crawler")

struct Crawler: Sendable {
    let httpClient: HermitHTTPClient

    /// Optional rate limiter; `nil` means requests are sent at full speed.
    let rateLimiter: RateLimiter?

    /// When `true`, the raw HTML body is kept in ``CrawledPage/html`` after fetching.
    ///
    /// Used by ``Hermit/crawlAndScrape(_:crawl:scrape:)`` so the scrape phase can reuse
    /// the already-fetched body without a second HTTP request.
    let captureHTML: Bool

    init(httpClient: HermitHTTPClient, rateLimiter: RateLimiter?, captureHTML: Bool = false) {
        self.httpClient = httpClient
        self.rateLimiter = rateLimiter
        self.captureHTML = captureHTML
    }

    /// Returns an `AsyncThrowingStream` that emits one ``CrawledPage`` per fetched URL.
    ///
    /// The stream ends naturally when the frontier is exhausted or ``CrawlConfiguration/maxPages``
    /// is reached. Individual page-fetch errors are captured in ``CrawledPage/error`` rather
    /// than being thrown, so a single failing URL does not abort the crawl.
    ///
    /// - Parameters:
    ///   - seed: The starting URL.
    ///   - configuration: Governs depth, concurrency, filtering, and domain policy.
    func crawlStream(
        seed: URL,
        configuration: CrawlConfiguration
    ) -> AsyncThrowingStream<CrawledPage, Error> {
        // The continuation is the bridge between the TaskGroup and the caller's async for-loop.
        // Pages are yielded as they complete — not in BFS order.
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await run(seed: seed, configuration: configuration, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// The main crawl loop: seeds the TaskGroup, drains results, and refills one-for-one.
    private func run(
        seed: URL,
        configuration: CrawlConfiguration,
        continuation: AsyncThrowingStream<CrawledPage, Error>.Continuation
    ) async throws {
        let frontier = CrawlFrontier(seed: seed, config: configuration)
        logger.debug("Crawl started", metadata: ["seed": "\(seed)", "maxDepth": "\(configuration.maxDepth)", "maxPages": "\(configuration.maxPages == .max ? "unlimited" : "\(configuration.maxPages)")", "concurrency": "\(configuration.concurrency)"])

        try await withThrowingTaskGroup(of: CrawledPage.self) { group in
            // Initial burst: fill the group up to the configured concurrency limit.
            for _ in 0..<configuration.concurrency {
                guard case .fetch(let url, let depth) = await frontier.next() else { break }
                addTask(to: &group, url: url, depth: depth)
            }
            logger.debug("Initial tasks seeded", metadata: ["concurrency": "\(configuration.concurrency)"])

            // Drain loop: process one result at a time, replacing it with a new task
            // from the frontier. This keeps concurrency constant without a semaphore.
            for try await page in group {
                continuation.yield(page)
                if let error = page.error {
                    logger.debug("Page fetch failed", metadata: ["url": "\(page.url)", "depth": "\(page.depth)", "error": "\(error)"])
                } else {
                    logger.debug("Page crawled", metadata: ["url": "\(page.url)", "depth": "\(page.depth)", "status": "\(page.statusCode.map(String.init) ?? "nil")", "links": "\(page.outboundLinks.count)"])
                }
                switch await frontier.complete(page) {
                case .fetch(let url, let depth):
                    // A new URL is ready — add a task to replace the one that just finished.
                    addTask(to: &group, url: url, depth: depth)
                case .idle:
                    // No URLs available yet, but other tasks are still running.
                    // They will surface more results and replenish the frontier.
                    logger.trace("Frontier idle, waiting for in-flight tasks")
                    break
                case .done:
                    // Frontier is exhausted and nothing is in-flight. Cancel any trailing
                    // tasks and exit the group.
                    logger.debug("Frontier exhausted, crawl complete")
                    group.cancelAll()
                    return
                }
            }
        }
    }

    /// Adds one fetch task to the group, rate-limiting if a limiter is configured.
    private func addTask(
        to group: inout ThrowingTaskGroup<CrawledPage, Error>,
        url: URL,
        depth: Int
    ) {
        logger.trace("Task dispatched", metadata: ["url": "\(url)", "depth": "\(depth)"])
        group.addTask {
            // Acquire a rate-limiter token before touching the network.
            try await rateLimiter?.acquire()
            return await fetchPage(url: url, depth: depth)
        }
    }

    /// Fetches a single page and wraps the result in a ``CrawledPage``.
    ///
    /// Errors are captured into the returned value rather than thrown so that one
    /// failing URL does not abort the entire crawl.
    private func fetchPage(url: URL, depth: Int) async -> CrawledPage {
        logger.trace("Fetching page", metadata: ["url": "\(url)", "depth": "\(depth)"])
        do {
            let result = try await httpClient.fetch(url, mode: .crawl)
            return CrawledPage(
                url: url,
                depth: depth,
                statusCode: result.statusCode,
                outboundLinks: result.links,
                html: captureHTML ? result.body : nil,
                error: nil
            )
        } catch {
            // Record the error on the page; the crawl continues with the remaining frontier.
            return CrawledPage(
                url: url,
                depth: depth,
                statusCode: nil,
                outboundLinks: [],
                html: nil,
                error: error
            )
        }
    }
}
