import Foundation

/// A compiled regular-expression pattern matched against absolute URL strings.
///
/// `URLPattern` is used in ``CrawlConfiguration/allowlist`` and ``CrawlConfiguration/denylist``
/// to include or exclude URLs from a crawl. The pattern is matched against the full absolute
/// URL string (e.g. `"https://example.com/blog/post-1"`).
///
/// You can create patterns from string literals, which is the most common usage:
///
/// ```swift
/// crawlConfig.denylist = ["/tag/", "/author/", "\\?s="]
/// crawlConfig.allowlist = ["/blog/\\d{4}/"]
/// ```
///
/// For patterns built from user input at runtime, use the throwing initialiser:
///
/// ```swift
/// let pattern = try URLPattern(userProvidedRegex)
/// ```
public struct URLPattern: Sendable, ExpressibleByStringLiteral {
    /// The raw regular-expression string this pattern was created from.
    public let rawValue: String

    /// The compiled regular expression used for matching.
    ///
    /// `Regex<AnyRegexOutput>` is the type produced when compiling a pattern from a
    /// string at runtime. It is part of the Swift standard library and requires no
    /// additional imports, making `URLPattern` compatible with Linux out of the box.
    private let regex: Regex<AnyRegexOutput>

    /// Creates a `URLPattern` from a regular-expression string, throwing if the pattern is invalid.
    ///
    /// - Parameter pattern: A regular-expression string compatible with Swift's `Regex` engine.
    /// - Throws: A `Regex` compilation error if the pattern is syntactically invalid.
    public init(_ pattern: String) throws {
        self.rawValue = pattern
        self.regex = try Regex(pattern)
    }

    /// Creates a `URLPattern` from a string literal.
    ///
    /// The regex is compiled at initialisation time. An invalid regex in a string literal is
    /// a programming error and will crash at launch.
    public init(stringLiteral value: String) {
        self.rawValue = value
        self.regex = try! Regex(value)
    }

    /// Returns `true` if this pattern matches anywhere in the URL's absolute string.
    ///
    /// - Parameter url: The URL to test.
    public func matches(_ url: URL) -> Bool {
        url.absoluteString.firstMatch(of: regex) != nil
    }
}
