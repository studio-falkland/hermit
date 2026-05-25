import Foundation
import Logging

/// Applies allowlist and denylist ``URLPattern`` rules to determine whether a URL should be visited.
///
/// The evaluation order is fixed:
/// 1. If the URL matches **any** denylist pattern → blocked.
/// 2. If the allowlist is non-empty and the URL matches **none** of its patterns → blocked.
/// 3. Otherwise → allowed.
///
/// Denylist always takes priority over allowlist.
private let logger = Logger(label: "Hermit.URLFilter")

struct URLFilter: Sendable {
    /// Patterns that restrict crawling to matching URLs only. Empty means "no restriction".
    let allowlist: [URLPattern]

    /// Patterns that unconditionally block matching URLs.
    let denylist: [URLPattern]

    /// Returns `true` if the URL passes both denylist and allowlist checks.
    ///
    /// - Parameter url: The URL to evaluate.
    func allows(_ url: URL) -> Bool {
        if denylist.contains(where: { $0.matches(url) }) {
            logger.trace("URL blocked by denylist", metadata: ["url": "\(url)"])
            return false
        }
        if !allowlist.isEmpty, !allowlist.contains(where: { $0.matches(url) }) {
            logger.trace("URL blocked by allowlist", metadata: ["url": "\(url)"])
            return false
        }
        logger.trace("URL allowed by filter", metadata: ["url": "\(url)"])
        return true
    }
}
