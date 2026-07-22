/// Options that control which HTML elements are preserved or stripped during Markdown conversion.
///
/// Pass an instance to ``ScrapeConfiguration/markdown`` to customise the output of
/// ``DefaultMarkdownConverter``.
///
/// ```swift
/// var opts = MarkdownOptions()
/// opts.denyTags = ["nav", "footer", "aside", "header"]
/// let config = ScrapeConfiguration(outputMarkdown: true, markdown: opts)
/// ```
public struct MarkdownOptions: Sendable {
    /// CSS selectors for elements to remove from the document before Markdown conversion.
    ///
    /// Each entry is passed directly to SwiftSoup's `select(_:)`, so any valid CSS selector
    /// works: tag names (`"nav"`), class selectors (`".ad-banner"`), attribute selectors
    /// (`"[role=navigation]"`), or compound selectors (`"nav, header"`).
    ///
    /// Defaults to `[]` (nothing removed).
    public let denyTags: [String]

    /// When `true`, converts `<a href>` elements to Markdown link syntax `[text](url)`.
    ///
    /// Defaults to `true`. Set to `false` to emit only the anchor's text content.
    public let preserveLinks: Bool

    /// When `true`, converts `<img>` elements to Markdown image syntax `![alt](src)`.
    ///
    /// Defaults to `true`. Set to `false` to drop images entirely.
    public let preserveImages: Bool

    /// Creates Markdown options.
    ///
    /// - Parameters:
    ///   - denyTags: Elements to remove before conversion (default: `[]`).
    ///   - preserveLinks: Convert `<a>` to Markdown links (default: `true`).
    ///   - preserveImages: Convert `<img>` to Markdown images (default: `true`).
    public init(
        denyTags: [String] = [],
        preserveLinks: Bool = true,
        preserveImages: Bool = true
    ) {
        self.denyTags = denyTags
        self.preserveLinks = preserveLinks
        self.preserveImages = preserveImages
    }

    /// The default Markdown options.
    public static let `default` = MarkdownOptions()
}