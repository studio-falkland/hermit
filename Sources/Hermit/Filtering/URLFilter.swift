import Foundation
import Logging

/// Applies whitelist and blacklist ``URLPattern`` rules to determine whether a URL should be visited.
///
/// The evaluation order is fixed:
/// 1. If the URL matches **any** blacklist pattern → blocked.
/// 2. If the whitelist is non-empty and the URL matches **none** of its patterns → blocked.
/// 3. Otherwise → allowed.
///
/// Blacklist always takes priority over whitelist.
private let logger = Logger(label: "Hermit.URLFilter")

struct URLFilter: Sendable {
    /// Patterns that restrict crawling to matching URLs only. Empty means "no restriction".
    let whitelist: [URLPattern]

    /// Patterns that unconditionally block matching URLs.
    let blacklist: [URLPattern]

    /// Returns `true` if the URL passes both blacklist and whitelist checks.
    ///
    /// - Parameter url: The URL to evaluate.
    func allows(_ url: URL) -> Bool {
        if blacklist.contains(where: { $0.matches(url) }) {
            logger.trace("URL blocked by blacklist", metadata: ["url": "\(url)"])
            return false
        }
        if !whitelist.isEmpty, !whitelist.contains(where: { $0.matches(url) }) {
            logger.trace("URL blocked by whitelist", metadata: ["url": "\(url)"])
            return false
        }
        logger.trace("URL allowed by filter", metadata: ["url": "\(url)"])
        return true
    }
}
