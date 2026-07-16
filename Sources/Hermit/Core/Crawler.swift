import AsyncHTTPClient
import Foundation
import NIOHTTP1
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

    /// Response-level filters evaluated against each page before the crawl GET.
    ///
    /// Filters are batched by ``FilterRequirements`` and run from cheapest to most
    /// expensive. A rejection in an earlier phase skips all later phases.
    let filters: [any CrawlFilter]

    init(
        httpClient: HermitHTTPClient,
        rateLimiter: RateLimiter?,
        captureHTML: Bool = false,
        filters: [any CrawlFilter] = []
    ) {
        self.httpClient = httpClient
        self.rateLimiter = rateLimiter
        self.captureHTML = captureHTML
        self.filters = filters
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
        logger.debug("Crawl started", metadata: ["seed": "\(seed)", "maxDepth": "\(configuration.maxDepth)", "maxPages": "\(configuration.maxPages == .max ? "unlimited" : "\(configuration.maxPages)")", "concurrency": "\(configuration.concurrency)", "filters": "\(filters.count)"])

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
    /// Runs the configured ``CrawlFilter`` instances in tiered phases (URL → HEAD → GET)
    /// before issuing the crawl GET. A rejection in any phase short-circuits the rest.
    /// Errors are captured into the returned value rather than thrown so that one
    /// failing URL does not abort the entire crawl.
    private func fetchPage(url: URL, depth: Int) async -> CrawledPage {
        logger.trace("Fetching page", metadata: ["url": "\(url)", "depth": "\(depth)"])

        // Run filters in tiered phases. If a filter rejects, return a rejected page.
        // If a body filter forces a GET and the page passes, reuse that response for
        // link extraction instead of issuing a second GET.
        do {
            let crawlResponse = try await runFilters(url: url)
            return CrawledPage(
                url: url,
                depth: depth,
                statusCode: Int(crawlResponse.status.code),
                outboundLinks: HTMLParser.extractLinks(
                    from: crawlResponse.body.map { String(buffer: $0) } ?? "",
                    base: url
                ),
                html: captureHTML ? crawlResponse.body.map { String(buffer: $0) } : nil,
                error: nil,
                responseHeaders: crawlResponse.headers
            )
        } catch let error as FilterRejection {
            logger.debug("Page rejected by filter", metadata: ["url": "\(url)", "filter": "\(error.filterName)"])
            return CrawledPage(
                url: url,
                depth: depth,
                statusCode: nil as Int?,
                outboundLinks: [],
                html: nil as String?,
                error: HermitError.filtered(url, filter: error.filterName),
                responseHeaders: HTTPHeaders()
            )
        } catch {
            // Record the error on the page; the crawl continues with the remaining frontier.
            return CrawledPage(
                url: url,
                depth: depth,
                statusCode: nil as Int?,
                outboundLinks: [],
                html: nil as String?,
                error: error,
                responseHeaders: HTTPHeaders()
            )
        }
    }

    /// Runs all configured filters in tiered phases and returns the response to crawl.
    ///
    /// - Phase 1 (`.url`): no request; run URL-only filters against a synthetic response.
    /// - Phase 2 (`.headers`): issue a HEAD; run header filters.
    /// - Phase 3 (`.body`): issue a GET; run body filters. The GET response is returned
    ///   for reuse by the crawl phase.
    ///
    /// If no filters require a body, a fresh crawl GET is issued and returned. If body
    /// filters were run, the GET response from Phase 3 is returned directly.
    ///
    /// - Parameter url: The URL being evaluated.
    /// - Returns: The response to use for link extraction.
    /// - Throws: ``FilterRejection`` if any filter rejects the page, or a network error.
    private func runFilters(url: URL) async throws -> HTTPClient.Response {
        // Partition filters by requirement level.
        let urlFilters = filters.filter { $0.requirements == .url }
        let headerFilters = filters.filter { $0.requirements == .headers }
        let bodyFilters = filters.filter { $0.requirements == .body }

        // Phase 1: URL-only filters. No request needed.
        if !urlFilters.isEmpty {
            let response = Self.makeURLOnlyResponse(url: url)
            for filter in urlFilters {
                if case .reject = await filter.allow(response) {
                    throw FilterRejection(filterName: String(describing: type(of: filter)))
                }
            }
        }

        // Determine the highest requirement across all filters.
        let maxRequirement = filters.map(\.requirements).max() ?? .url

        // Phase 2 & 3: issue the minimal request that satisfies all filters.
        // If any filter needs the body, issue a GET and reuse it for both body filters
        // and the crawl. Otherwise, issue a HEAD for header filters, then a separate
        // crawl GET.
        if maxRequirement == .body {
            // Phase 3: GET (also satisfies Phase 2).
            let response = try await httpClient.get(url)

            // Run header filters against the GET response (which has headers).
            for filter in headerFilters {
                if case .reject = await filter.allow(response) {
                    throw FilterRejection(filterName: String(describing: type(of: filter)))
                }
            }
            // Run body filters.
            for filter in bodyFilters {
                if case .reject = await filter.allow(response) {
                    throw FilterRejection(filterName: String(describing: type(of: filter)))
                }
            }
            // Reuse this GET response for the crawl — no second request.
            return response
        } else if maxRequirement == .headers {
            // Phase 2: HEAD only.
            let response = try await httpClient.head(url)
            for filter in headerFilters {
                if case .reject = await filter.allow(response) {
                    throw FilterRejection(filterName: String(describing: type(of: filter)))
                }
            }
            // No body filters; issue the normal crawl GET.
            return try await httpClient.get(url)
        } else {
            // Only URL filters (or no filters at all). Issue the crawl GET directly.
            return try await httpClient.get(url)
        }
    }

    /// Constructs a minimal `HTTPClient.Response` carrying only the URL.
    ///
    /// Used for Phase 1 (`.url` filters). The `url` property is derived from
    /// `history.last?.request.url`, so we synthesise a single-entry history.
    private static func makeURLOnlyResponse(url: URL) -> HTTPClient.Response {
        // Build a synthetic request/response pair so that `response.url` resolves.
        // `HTTPClient.Request` is the older API that exposes a public initialiser
        // taking a `URL`; it is still available alongside `HTTPClientRequest`.
        let request: HTTPClient.Request
        do {
            request = try HTTPClient.Request(url: url)
        } catch {
            // Fallback for URLs that AsyncHTTPClient rejects (e.g. non-http schemes).
            // The filter will see a nil `response.url` and should handle that.
            return HTTPClient.Response(
                host: "",
                status: .ok,
                version: .http1_1,
                headers: HTTPHeaders(),
                body: nil,
                history: []
            )
        }
        let head = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: HTTPHeaders()
        )
        let requestResponse = HTTPClient.RequestResponse(
            request: request,
            responseHead: head
        )
        return HTTPClient.Response(
            host: request.host,
            status: .ok,
            version: .http1_1,
            headers: HTTPHeaders(),
            body: nil,
            history: [requestResponse]
        )
    }
}

/// An internal error used to short-circuit filter evaluation when a filter rejects a page.
///
/// Carries the name of the rejecting filter type so it can be surfaced via
/// ``HermitError/filtered(_:filter:)``.
private struct FilterRejection: Error {
    let filterName: String
}
