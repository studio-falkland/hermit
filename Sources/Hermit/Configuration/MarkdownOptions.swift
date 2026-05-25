/// Options that control which HTML elements are preserved or stripped during Markdown conversion.
///
/// Pass an instance to ``ScrapeConfiguration/markdown`` to customise the output of
/// ``DefaultMarkdownConverter``.
///
/// ```swift
/// hermit.scrape("https://example.com/article") {
///     $0.outputMarkdown = true
///     $0.markdown.denyTags = ["nav", "footer", "aside", "header"]
/// }
/// ```
public struct MarkdownOptions: Sendable {
    /// CSS selectors for elements to remove from the document before Markdown conversion.
    ///
    /// Each entry is passed directly to SwiftSoup's `select(_:)`, so any valid CSS selector
    /// works: tag names (`"nav"`), class selectors (`".ad-banner"`), attribute selectors
    /// (`"[role=navigation]"`), or compound selectors (`"nav, header"`).
    ///
    /// Defaults to `[]` (nothing removed).
    public var denyTags: [String] = []

    /// When `true`, converts `<a href>` elements to Markdown link syntax `[text](url)`.
    ///
    /// Defaults to `true`. Set to `false` to emit only the anchor's text content.
    public var preserveLinks: Bool = true

    /// When `true`, converts `<img>` elements to Markdown image syntax `![alt](src)`.
    ///
    /// Defaults to `true`. Set to `false` to drop images entirely.
    public var preserveImages: Bool = true

    /// The default Markdown options.
    public static let `default` = MarkdownOptions()
}
