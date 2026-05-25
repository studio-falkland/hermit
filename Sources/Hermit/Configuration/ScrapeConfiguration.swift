/// Configuration for a scrape operation.
///
/// Pass an instance to ``Hermit/scrape(_:configure:)`` or ``Hermit/scrapeStream(_:configure:)``
/// using the trailing closure syntax:
///
/// ```swift
/// let page = try await hermit.scrape("https://example.com/article") {
///     $0.outputMarkdown = true
///     $0.markdown.denyTags = ["nav", "footer"]
///     $0.extractions = ["title": "h1", "author": ".byline"]
/// }
/// ```
public struct ScrapeConfiguration: Sendable {
    /// When `true`, the HTML body is converted to Markdown and stored in ``ScrapedPage/markdown``.
    ///
    /// Conversion is performed by the ``MarkdownConverter`` set on the ``Hermit`` instance.
    /// Defaults to `false`.
    public var outputMarkdown: Bool = false

    /// Options that control Markdown conversion behaviour, such as element stripping.
    ///
    /// Only meaningful when ``outputMarkdown`` is `true`.
    public var markdown: MarkdownOptions = .default

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
    public var extractions: [String: String] = [:]

    /// HTTP-level settings such as user agent, timeout, and custom headers.
    public var network: NetworkConfiguration = .default

    /// The default scrape configuration.
    public static let `default` = ScrapeConfiguration()
}
