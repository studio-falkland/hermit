import AsyncHTTPClient
import Collections
import Foundation
import NIOHTTP1
import Logging

private let logger = Logger(label: "Hermit.CrawlDriver")

/// Drives a BFS crawl, owning both frontier state and fetch machinery.
///
/// Frontier operations (`next`, `complete`) are actor-isolated — they mutate the queue
/// and visited set. Fetch operations (`fetchPage`) are ``nonisolated`` since they only
/// touch the HTTP client, rate limiter, and filters — none of which require actor
/// isolation.
///
/// Both ``Hermit/crawlStream(_:configuration:)`` and ``Hermit/crawlAndScrape(_:configuration:scrapeConfiguration:onCrawlFailure:)``
/// create a `CrawlDriver` directly.
actor CrawlDriver {
    // MARK: Frontier state

    /// BFS queue of (url, depth) pairs waiting to be fetched.
    private var queue: Deque<(url: URL, depth: Int)> = []

    /// Every URL that has ever been enqueued: queued, in-flight, or completed.
    ///
    /// A URL is inserted here at enqueue time, never later. This is the sole deduplication gate.
    private(set) var visited: Set<URL> = []

    /// The count of tasks that have dequeued a URL but have not yet called ``complete(_:)``.
    private var inFlight: Int = 0

    private let urlFilter: URLFilter
    private let domainPolicy: DomainPolicy

    // MARK: Configuration & machinery (nonisolated — never touches frontier state)

    /// The crawl configuration. ``nonisolated`` so both actor and fetch code can read it.
    nonisolated let config: CrawlConfiguration
    nonisolated let httpClient: HermitHTTPClient
    nonisolated let rateLimiter: RateLimiter?

    // MARK: Types

    /// The result returned by ``complete(_:)`` and ``next()``.
    enum Advance {
        /// A URL is ready to be fetched at the given depth.
        case fetch(url: URL, depth: Int)

        /// The queue is currently empty but tasks are still in-flight; the crawl is not done.
        case idle

        /// The queue is empty and no tasks are in-flight — the crawl is complete.
        case done
    }

    // MARK: Initialization

    init(
        seed: URL,
        config: CrawlConfiguration,
        httpClient: HermitHTTPClient,
        rateLimiter: RateLimiter?
    ) {
        self.config = config
        self.urlFilter = URLFilter(allowlist: config.allowlist, denylist: config.denylist)
        self.domainPolicy = DomainPolicy(
            seedHost: seed.host?.lowercased() ?? "",
            stayOnDomain: config.stayOnDomain,
            includeSubdomains: config.includeSubdomains
        )
        self.httpClient = httpClient
        self.rateLimiter = rateLimiter
        visited.insert(seed)
        queue.append((seed, 0))
        logger.debug("Driver initialized", metadata: ["seed": "\(seed)", "maxDepth": "\(config.maxDepth)", "maxPages": "\(config.maxPages == .max ? "unlimited" : "\(config.maxPages)")"])
    }

    // MARK: Frontier operations (actor-isolated)

    /// Dequeues the next URL to fetch, or signals idle/done.
    func next() -> Advance {
        guard !queue.isEmpty, visited.count < Int(config.maxPages) else {
            if inFlight == 0 {
                logger.debug("Frontier done", metadata: ["visited": "\(visited.count)"])
                return .done
            }
            logger.trace("Frontier idle", metadata: ["inFlight": "\(inFlight)", "visited": "\(visited.count)"])
            return .idle
        }
        let item = queue.removeFirst()
        inFlight += 1
        logger.trace("Dequeued URL", metadata: ["url": "\(item.url)", "depth": "\(item.depth)", "queued": "\(queue.count)", "inFlight": "\(inFlight)"])
        return .fetch(url: item.url, depth: item.depth)
    }

    /// Records a completed fetch, enqueues eligible discovered links, and returns the next
    /// URL to fetch — all in a single actor hop.
    ///
    /// - Parameter page: The ``CrawledPage`` that just finished.
    /// - Returns: An ``Advance`` indicating what the calling task should do next.
    func complete(_ page: CrawledPage) -> Advance {
        inFlight -= 1

        if page.depth < Int(config.maxDepth) {
            let maxPages = Int(config.maxPages)
            for link in page.outboundLinks {
                if visited.contains(link) {
                    logger.trace("Skipping link: already visited", metadata: ["url": "\(link)"])
                    continue
                }
                if visited.count >= maxPages {
                    logger.trace("Skipping link: page limit reached", metadata: ["url": "\(link)", "limit": "\(maxPages)"])
                    continue
                }
                if !urlFilter.allows(link) {
                    logger.trace("Skipping link: blocked by URL filter", metadata: ["url": "\(link)"])
                    continue
                }
                if !domainPolicy.allows(link) {
                    logger.trace("Skipping link: blocked by domain policy", metadata: ["url": "\(link)"])
                    continue
                }
                logger.trace("Enqueuing link", metadata: ["url": "\(link)", "depth": "\(page.depth + 1)", "queueSize": "\(queue.count + 1)"])
                visited.insert(link)
                queue.append((link, page.depth + 1))
            }
        } else {
            logger.trace("At max depth, not enqueuing links", metadata: ["url": "\(page.url)", "depth": "\(page.depth)"])
        }

        return next()
    }

    // MARK: Fetch (nonisolated — no actor-state access)

    /// Fetches a single page and wraps the result in a ``CrawledPage``.
    ///
    /// Runs the configured ``CrawlFilter`` instances in tiered phases (URL → HEAD → GET)
    /// before issuing the crawl GET. A rejection in any phase short-circuits the rest.
    /// Errors are captured into the returned value rather than thrown.
    ///
    /// - Note: Callers should acquire the rate limiter token themselves before calling.
    nonisolated func fetchPage(url: URL, depth: Int) async -> CrawledPage {
        logger.trace("Fetching page", metadata: ["url": "\(url)", "depth": "\(depth)"])

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
                html: config.captureHTML ? crawlResponse.body.map { String(buffer: $0) } : nil,
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
                error: HermitError.filtered(url, filter: error.filterName, context: error.context),
                responseHeaders: HTTPHeaders()
            )
        } catch {
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

    // MARK: Filter pipeline (nonisolated helpers)

    /// Runs all configured filters in tiered phases and returns the response to crawl.
    ///
    /// - Phase 1 (`.url`): no request; run URL-only filters against a synthetic response.
    /// - Phase 2 (`.headers`): issue a HEAD; run header filters.
    /// - Phase 3 (`.body`): issue a GET; run body filters. The GET response is returned
    ///   for reuse by the crawl phase.
    private nonisolated func runFilters(url: URL) async throws -> HTTPClient.Response {
        let filters = config.filters
        let urlFilters = filters.filter { $0.requirements == .url }
        let headerFilters = filters.filter { $0.requirements == .headers }
        let bodyFilters = filters.filter { $0.requirements == .body }

        if !urlFilters.isEmpty {
            let response = Self.makeURLOnlyResponse(url: url)
            for filter in urlFilters {
                if case .reject = try await filter.allow(response) {
                    throw FilterRejection(
                        filterName: String(describing: type(of: filter)),
                        context: .empty
                    )
                }
            }
        }

        let maxRequirement = filters.map(\.requirements).max() ?? .url

        if maxRequirement == .body {
            let response = try await httpClient.get(url)
            try await Self.runResponseFilters(headerFilters, against: response)
            try await Self.runResponseFilters(bodyFilters, against: response)
            return response
        } else if maxRequirement == .headers {
            let headResponse = try await httpClient.head(url)
            try await Self.runResponseFilters(headerFilters, against: headResponse)
            let getResponse = try await httpClient.get(url)
            try await Self.runResponseFilters(headerFilters, against: getResponse)
            return getResponse
        } else {
            return try await httpClient.get(url)
        }
    }

    /// Evaluates a batch of filters against a single response, throwing
    /// ``FilterRejection`` on the first rejection.
    private static func runResponseFilters(
        _ filters: [any CrawlFilter],
        against response: HTTPClient.Response
    ) async throws {
        let context = Self.context(from: response)
        for filter in filters {
            if case .reject = try await filter.allow(response) {
                throw FilterRejection(
                    filterName: String(describing: type(of: filter)),
                    context: context
                )
            }
        }
    }

    /// Builds a ``FilterContext`` from a response that was just fetched.
    private static func context(from response: HTTPClient.Response) -> FilterContext {
        FilterContext(
            statusCode: Int(response.status.code),
            contentType: mimeType(from: response.headers)
        )
    }

    /// Extracts the bare MIME type from a `Content-Type` header.
    private static func mimeType(from headers: HTTPHeaders) -> String? {
        guard let raw = headers.first(name: "content-type") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(separator: ";")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Constructs a minimal `HTTPClient.Response` carrying only the URL.
    private static func makeURLOnlyResponse(url: URL) -> HTTPClient.Response {
        let request: HTTPClient.Request
        do {
            request = try HTTPClient.Request(url: url)
        } catch {
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

/// A discriminated union of the two kinds of task in the merged crawl+scrape group.
enum CrawlScrapeStep: Sendable {
    case crawled(CrawledPage)
    case scraped(ScrapedPage)
}

/// An internal error used to short-circuit filter evaluation when a filter rejects a page.
private struct FilterRejection: Error {
    let filterName: String
    let context: FilterContext
}
