import Collections
import Foundation
import Logging

/// An actor that manages the BFS crawl frontier: the queue of URLs to visit and the
/// set of all URLs ever seen.
///
/// `CrawlFrontier` is the single source of truth for deduplication. A URL enters
/// ``visited`` at the moment it is enqueued — before it is ever fetched — so every URL
/// in the queue, currently in-flight, or already completed is present in ``visited``.
/// The `!visited.contains(link)` guard in ``complete(_:)`` is the one and only place
/// where duplicate URLs are filtered out.
///
/// All mutations happen inside the actor's serial executor, so no external locking
/// or synchronisation is required.
private let logger = Logger(label: "Hermit.CrawlFrontier")

actor CrawlFrontier {
    /// BFS queue of (url, depth) pairs waiting to be fetched.
    ///
    /// `Deque` is used instead of `Array` for O(1) `removeFirst`.
    private var queue: Deque<(url: URL, depth: Int)> = []

    /// Every URL that has ever been enqueued: currently queued, in-flight, or completed.
    ///
    /// A URL is inserted here at enqueue time, never later. This is the sole deduplication gate.
    private(set) var visited: Set<URL> = []

    /// The count of tasks that have dequeued a URL but have not yet called ``complete(_:)``.
    private var inFlight: Int = 0

    private let config: CrawlConfiguration
    private let urlFilter: URLFilter
    private let domainPolicy: DomainPolicy

    /// The result returned by ``complete(_:)`` and ``next()``.
    enum Advance {
        /// A URL is ready to be fetched at the given depth.
        case fetch(url: URL, depth: Int)

        /// The queue is currently empty but tasks are still in-flight; the crawl is not done.
        case idle

        /// The queue is empty and no tasks are in-flight — the crawl is complete.
        case done
    }

    /// Creates a new frontier seeded with a single starting URL.
    ///
    /// The seed is immediately inserted into ``visited`` and enqueued, so it counts
    /// against ``CrawlConfiguration/maxPages``.
    ///
    /// - Parameters:
    ///   - seed: The URL from which the crawl begins.
    ///   - config: The crawl configuration that governs depth, page limits, and filtering.
    init(seed: URL, config: CrawlConfiguration) {
        self.config = config
        self.urlFilter = URLFilter(whitelist: config.whitelist, blacklist: config.blacklist)
        self.domainPolicy = DomainPolicy(
            seedHost: seed.host?.lowercased() ?? "",
            stayOnDomain: config.stayOnDomain,
            includeSubdomains: config.includeSubdomains
        )
        // Mark the seed as visited immediately so no concurrent task can re-enqueue it.
        visited.insert(seed)
        queue.append((seed, 0))
        logger.debug("Frontier initialized", metadata: ["seed": "\(seed)", "maxDepth": "\(config.maxDepth)", "maxPages": "\(config.maxPages == .max ? "unlimited" : "\(config.maxPages)")"])
    }

    /// Records a completed fetch, enqueues eligible discovered links, and returns the next
    /// URL to fetch — all in a single actor hop.
    ///
    /// Combining these two operations halves the number of actor messages per task compared
    /// to calling separate `complete` and `next` methods, reducing actor-queue contention
    /// at high concurrency.
    ///
    /// - Parameter page: The ``CrawledPage`` that just finished.
    /// - Returns: An ``Advance`` indicating what the calling task should do next.
    func complete(_ page: CrawledPage) -> Advance {
        inFlight -= 1

        // Only enqueue child links if we haven't already exceeded the max depth for this branch.
        if page.depth < config.maxDepth {
            for link in page.outboundLinks {
                if visited.contains(link) {
                    logger.trace("Skipping link: already visited", metadata: ["url": "\(link)"])
                    continue
                }
                if visited.count >= config.maxPages {
                    logger.trace("Skipping link: page limit reached", metadata: ["url": "\(link)", "limit": "\(config.maxPages)"])
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

    /// Dequeues the next URL to fetch, or signals that the crawl is idle or complete.
    ///
    /// Called during the initial seeding burst and also at the end of ``complete(_:)``
    /// to atomically hand the caller a new unit of work.
    func next() -> Advance {
        guard !queue.isEmpty, visited.count < config.maxPages else {
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
}
