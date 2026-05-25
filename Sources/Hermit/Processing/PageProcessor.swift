/// A protocol for post-processing a ``ScrapedPage`` after it has been fetched and parsed.
///
/// Implement this protocol to add custom transformation, enrichment, or side-effect logic
/// to every page that passes through a scrape pipeline. Processors are called in the order
/// they appear in ``Hermit/init(configuration:eventLoopGroupProvider:processors:markdownConverter:)``.
///
/// ```swift
/// struct WordCounter: PageProcessor {
///     func process(_ page: ScrapedPage) async throws -> ScrapedPage {
///         let count = page.markdown?.split(separator: " ").count ?? 0
///         print("\(page.url.path): \(count) words")
///         return page  // return a modified copy to transform the page, or the original to pass it through
///     }
/// }
///
/// let hermit = Hermit(processors: [WordCounter()])
/// ```
public protocol PageProcessor: Sendable {
    /// Processes a scraped page and returns either the same or a transformed copy.
    ///
    /// - Parameter page: The page that was just scraped and parsed.
    /// - Returns: The page, optionally modified.
    /// - Throws: Any error that should abort processing of this page.
    func process(_ page: ScrapedPage) async throws -> ScrapedPage
}
