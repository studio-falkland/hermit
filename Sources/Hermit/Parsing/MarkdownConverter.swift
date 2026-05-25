import SwiftSoup
import Foundation
import Logging

private let logger = Logger(label: "Hermit.MarkdownConverter")

/// A type that converts a parsed HTML document into a Markdown string.
///
/// Hermit ships with ``DefaultMarkdownConverter``. Provide a custom implementation to
/// ``Hermit/init(configuration:eventLoopGroupProvider:processors:markdownConverter:)`` to
/// replace or extend the default conversion logic.
///
/// ```swift
/// struct MyConverter: MarkdownConverter {
///     func convert(document: Document, baseURL: URL, options: MarkdownOptions) throws -> String {
///         // custom logic
///     }
/// }
///
/// let hermit = Hermit(markdownConverter: MyConverter())
/// ```
public protocol MarkdownConverter: Sendable {
    /// Converts an already-parsed HTML document to Markdown.
    ///
    /// Prefer this over the `html:` convenience when you already hold a parsed `Document`
    /// (e.g. from ``HTMLParser/parse(_:url:)``), to avoid a redundant SwiftSoup parse.
    ///
    /// - Parameters:
    ///   - document: The parsed HTML document to convert.
    ///   - baseURL: The page's URL, used to resolve relative links and images to absolute URLs.
    ///   - options: Controls which structural elements are suppressed before conversion.
    /// - Returns: A Markdown string.
    /// - Throws: Any error encountered during conversion.
    func convert(document: Document, baseURL: URL, options: MarkdownOptions) throws -> String
}

public extension MarkdownConverter {
    /// Convenience that parses `html` then delegates to ``convert(document:baseURL:options:)``.
    ///
    /// Use this when you only have a raw HTML string. When you already hold a parsed
    /// `Document` (e.g. from ``HTMLParser/parse(_:url:)``), prefer calling
    /// ``convert(document:baseURL:options:)`` directly to avoid a redundant parse.
    func convert(html: String, baseURL: URL, options: MarkdownOptions) throws -> String {
        let doc = try SwiftSoup.parse(html, baseURL.absoluteString)
        return try convert(document: doc, baseURL: baseURL, options: options)
    }
}

/// The default HTML-to-Markdown converter included with Hermit.
///
/// Accepts an already-parsed SwiftSoup `Document`, optionally suppresses structural elements
/// (nav, header, footer, aside), skips scripts and styles, then recursively walks the DOM tree
/// converting each element to its Markdown equivalent.
///
/// Supported elements: headings (h1–h6), paragraphs, bold, italic, inline code, fenced code
/// blocks, blockquotes, ordered and unordered lists, links, images, and tables.
/// Unrecognised elements pass through their inner text content without any Markdown wrapping.
public struct DefaultMarkdownConverter: MarkdownConverter {
    public init() {}

    /// Converts the document to Markdown.
    ///
    /// Called from ``Scraper`` after metadata and CSS extractions are already complete,
    /// so mutating the document here is safe — no further queries run against it before
    /// it is stored in ``ScrapedPage``.
    public func convert(document: Document, baseURL: URL, options: MarkdownOptions) throws -> String {
        logger.debug("Converting HTML to Markdown", metadata: ["url": "\(baseURL)"])

        if !options.denyTags.isEmpty {
            try document.select(options.denyTags.joined(separator: ", ")).remove()
        }
        logger.trace("Elements stripped", metadata: ["url": "\(baseURL)", "selectors": "\(options.denyTags)"])
        // Always remove non-content elements that would produce garbage in Markdown.
        try document.select("script, style, noscript").remove()

        guard let body = document.body() else { return "" }
        logger.trace("Walking DOM for Markdown output", metadata: ["url": "\(baseURL)"])
        var output = convertNode(body, options: options)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        logger.debug("Markdown conversion complete", metadata: ["url": "\(baseURL)", "outputBytes": "\(output.utf8.count)"])
        return output
    }

    /// Recursively converts a DOM node to its Markdown representation.
    ///
    /// Text nodes return their text directly. Element nodes are converted based on their
    /// tag name. Unrecognised tags pass through their children's output, preserving text
    /// content without adding any Markdown syntax.
    private func convertNode(_ node: Node, options: MarkdownOptions) -> String {
        // Leaf text node — return its text content directly.
        if let text = node as? TextNode { return text.text() }
        guard let el = node as? Element else {
            // Non-element, non-text node (e.g. comment) — recurse into children.
            return node.getChildNodes().map { convertNode($0, options: options) }.joined()
        }

        let tag = el.tagName().lowercased()
        // Recursively convert all children before deciding what wrapping to apply.
        let inner = el.getChildNodes().map { convertNode($0, options: options) }.joined()

        switch tag {
        case "h1": return "\n\n# \(inner)\n\n"
        case "h2": return "\n\n## \(inner)\n\n"
        case "h3": return "\n\n### \(inner)\n\n"
        case "h4": return "\n\n#### \(inner)\n\n"
        case "h5": return "\n\n##### \(inner)\n\n"
        case "h6": return "\n\n###### \(inner)\n\n"
        case "p": return "\n\n\(inner)\n\n"
        case "br": return "\n"
        case "hr": return "\n\n---\n\n"
        case "strong", "b": return "**\(inner)**"
        case "em", "i": return "_\(inner)_"
        // Inline code unless the parent is a <pre> block, in which case pre handles the fencing.
        case "code": return el.parent()?.tagName() == "pre" ? inner : "`\(inner)`"
        case "pre": return "\n\n```\n\(inner)\n```\n\n"
        case "blockquote":
            let quoted = inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n")
            return "\n\n\(quoted)\n\n"
        case "ul":
            return "\n\n" + el.children().map {
                "- " + convertNode($0, options: options).trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n") + "\n\n"
        case "ol":
            // Number each <li> sequentially starting at 1.
            return "\n\n" + el.children().enumerated().map { i, li in
                "\(i + 1). " + convertNode(li, options: options).trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n") + "\n\n"
        case "li": return inner
        case "a":
            if options.preserveLinks,
               let href = try? el.attr("abs:href"), !href.isEmpty {
                return "[\(inner)](\(href))"
            }
            // No href or links disabled — emit just the visible text.
            return inner
        case "img":
            if options.preserveImages,
               let src = try? el.attr("abs:src"), !src.isEmpty {
                let alt = (try? el.attr("alt")) ?? ""
                return "![\(alt)](\(src))"
            }
            return ""
        case "table": return convertTable(el, options: options)
        // Structural and generic containers — pass children through unchanged.
        default: return inner
        }
    }

    /// Converts an HTML table into a Markdown pipe table.
    ///
    /// The first row becomes the header row; a separator row of `---` cells is inserted
    /// beneath it. All subsequent rows are treated as body rows.
    private func convertTable(_ table: Element, options: MarkdownOptions) -> String {
        let allRows = (try? table.select("tr")) ?? Elements()
        // Convert every cell in every row to a trimmed Markdown string.
        let rows: [[String]] = allRows.map { row in
            ((try? row.select("td, th")) ?? Elements()).map { cell in
                convertNode(cell, options: options).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let header = rows.first else { return "" }
        // Build the header row and its separator.
        var out = "\n\n| " + header.joined(separator: " | ") + " |"
        out += "\n| " + header.map { _ in "---" }.joined(separator: " | ") + " |"
        for row in rows.dropFirst() {
            out += "\n| " + row.joined(separator: " | ") + " |"
        }
        return out + "\n\n"
    }
}
