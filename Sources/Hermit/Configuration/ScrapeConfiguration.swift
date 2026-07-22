/// Configuration for a scrape operation.
///
/// Pass an instance to ``Hermit/scrape(_:configuration:)`` or ``Hermit/scrapeStream(_:configuration:)``.
///
/// ```swift
/// let config = ScrapeConfiguration(outputMarkdown: true, extractions: ["title": "h1"])
/// let page = try await hermit.scrape("https://example.com/article", configuration: config)
/// ```
public struct ScrapeConfiguration: Sendable {
    /// When `true`, the HTML body is converted to Markdown and stored in ``ScrapedPage/markdown``.
    ///
    /// Conversion is performed by the ``MarkdownConverter`` set on the ``Hermit`` instance.
    /// Defaults to `false`.
    public let outputMarkdown: Bool

    /// Options that control Markdown conversion behaviour, such as element stripping.
    ///
    /// Only meaningful when ``outputMarkdown`` is `true`.
    public let markdown: MarkdownOptions

    /// Named CSS selectors whose matched text is stored in ``ScrapedPage/extractions``.
    ///
    /// Each key becomes a key in the result dictionary; each value is a CSS selector.
    /// The trimmed text content of the first matching element is extracted.
    ///
    /// ```swift
    /// $0.extractions = [
    ///     "headline": "h1",
    ///     "author":   ".byline",
    ///     "pubDate":  "time[datetime]"
    /// ]
    /// ```
    public let extractions: [String: String]

    /// HTTP-level settings such as user agent, timeout, and custom headers.
    public let network: NetworkConfiguration

    /// Creates a scrape configuration.
    ///
    /// - Parameters:
    ///   - outputMarkdown: Whether to convert HTML to Markdown (default: `false`).
    ///   - markdown: Options controlling Markdown conversion (default: `.default`).
    ///   - extractions: Named CSS selectors for extracting text (default: `[:]`).
    ///   - network: HTTP-level settings (default: `.default`).
    public init(
        outputMarkdown: Bool = false,
        markdown: MarkdownOptions = .default,
        extractions: [String: String] = [:],
        network: NetworkConfiguration = .default
    ) {
        self.outputMarkdown = outputMarkdown
        self.markdown = markdown
        self.extractions = extractions
        self.network = network
    }

    /// The default scrape configuration.
    public static let `default` = ScrapeConfiguration()
}