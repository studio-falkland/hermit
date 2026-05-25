import Foundation

/// Structured metadata extracted from a scraped HTML page.
///
/// Populated by ``HTMLParser/extractMetadata(from:base:)`` and attached to every ``ScrapedPage``.
public struct PageMetadata: Sendable {
    /// The content of the page's `<title>` element, if present.
    public let title: String?

    /// The content of the `<meta name="description">` tag, if present.
    public let description: String?

    /// The canonical URL declared via `<link rel="canonical">`, if present.
    public let canonicalURL: URL?

    /// Open Graph metadata keyed by property name (e.g. `"og:title"`, `"og:image"`).
    public let openGraph: [String: String]

    /// All hyperlinks found in the page body, with text and domain classification.
    public let links: [PageLink]

    /// All images found in the page body.
    public let images: [PageImage]
}

/// A hyperlink discovered on a scraped page.
public struct PageLink: Sendable {
    /// The resolved absolute URL of the link.
    public let url: URL

    /// The visible anchor text, trimmed of whitespace.
    public let text: String

    /// `true` if the link points to a different host than the page it was found on.
    public let isExternal: Bool
}

/// An image discovered on a scraped page.
public struct PageImage: Sendable {
    /// The resolved absolute URL of the image source.
    public let url: URL

    /// The `alt` attribute text, or `nil` if absent or empty.
    public let alt: String?

    /// The `width` attribute value in pixels, if present and parseable as an integer.
    public let width: Int?

    /// The `height` attribute value in pixels, if present and parseable as an integer.
    public let height: Int?
}
