import Foundation
import Logging

/// Enforces domain-level crawl restrictions based on the seed URL's host.
///
/// Used by ``CrawlDriver`` to decide whether a discovered link should be enqueued.
/// Configured by ``CrawlConfiguration/stayOnDomain`` and ``CrawlConfiguration/includeSubdomains``.
private let logger = Logger(label: "Hermit.DomainPolicy")

struct DomainPolicy: Sendable {
    /// The lowercased host of the seed URL (e.g. `"example.com"`).
    let seedHost: String

    /// When `true`, only URLs on `seedHost` (and optionally its subdomains) are allowed.
    let stayOnDomain: Bool

    /// When `true` and `stayOnDomain` is `true`, subdomain URLs are also allowed.
    let includeSubdomains: Bool

    /// Returns `true` if the URL is allowed under the domain policy.
    ///
    /// - Parameter url: The URL to evaluate.
    func allows(_ url: URL) -> Bool {
        guard stayOnDomain else {
            logger.trace("Domain policy off, URL allowed", metadata: ["url": "\(url)"])
            return true
        }
        guard let host = url.host?.lowercased() else {
            logger.trace("URL has no host, blocked", metadata: ["url": "\(url)"])
            return false
        }
        let allowed: Bool
        if includeSubdomains {
            allowed = host == seedHost || host.hasSuffix(".\(seedHost)")
        } else {
            allowed = host == seedHost
        }
        if allowed {
            logger.trace("URL allowed by domain policy", metadata: ["url": "\(url)", "host": "\(host)"])
        } else {
            logger.trace("URL blocked by domain policy", metadata: ["url": "\(url)", "host": "\(host)", "seedHost": "\(seedHost)"])
        }
        return allowed
    }
}
