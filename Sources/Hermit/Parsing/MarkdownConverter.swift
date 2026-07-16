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
/// The `Document` passed to ``convert(document:baseURL:options:)`` is task-local and must
/// not escape the call — SwiftSoup's per-element state is not safe to access from another
/// task. Return only the resulting Markdown string.
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
/// (nav, header, footer, aside), skips scripts and styles, then uses an iterative DOM walk
/// to convert each element to its Markdown equivalent. The iterative approach uses a
/// heap-allocated stack instead of the CPU call stack, making it safe for deeply nested HTML
/// that would overflow a fixed-size task stack inside a `TaskGroup`.
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

    /// Converts a DOM node and its entire subtree to Markdown using an iterative walk.
    ///
    /// An explicit `Array` on the heap replaces the CPU call stack. Each ``Frame`` tracks
    /// a single node, the next child index to process, and accumulated results from already-
    /// processed children. Text nodes are leaves that contribute their text immediately.
    /// Element nodes push all children as new frames, then on the "exit" pass (when all
    /// children are done) the tag-specific wrapping is applied.
    ///
    /// This avoids unbounded CPU stack growth, which is especially important inside
    /// `TaskGroup` child tasks that have smaller default stacks than the main thread.
    private func convertNode(_ root: Node, options: MarkdownOptions) -> String {
        /// Per-node state in the explicit walk stack.
        struct Frame {
            let node: Node
            /// Index of the next child to push onto the stack.
            var nextChild: Int = 0
            /// Converted outputs from children that have already been processed.
            var childResults: [String] = []
        }

        var stack: [Frame] = [Frame(node: root)]

        while let frame = stack.popLast() {
            // ── Text node leaf ─────────────────────────────────────────
            if let text = frame.node as? TextNode {
                let content = text.text()
                guard !stack.isEmpty else { return content }
                stack[stack.count - 1].childResults.append(content)
                continue
            }

            guard let el = frame.node as? Element else {
                // Non-element, non-text node (comment, etc.) — process as generic container.
                let children = frame.node.getChildNodes()
                guard frame.nextChild < children.count else {
                    // All children processed; the inner text is just the joined child results.
                    let inner = frame.childResults.joined()
                    guard !stack.isEmpty else { return inner }
                    stack[stack.count - 1].childResults.append(inner)
                    continue
                }
                // Push the next child (reverse order so they're processed front-to-back).
                let child = children[children.count - 1 - frame.nextChild]
                stack.append(Frame(node: frame.node, nextChild: frame.nextChild + 1, childResults: frame.childResults))
                stack.append(Frame(node: child))
                continue
            }

            // ── Element node ───────────────────────────────────────────
            let children = el.getChildNodes()
            guard frame.nextChild < children.count else {
                // All children have been processed. Apply tag-specific conversion.
                let inner = frame.childResults.joined()
                let tag = el.tagName().lowercased()
                let result = tagResult(for: el, tag: tag, inner: inner, options: options)
                guard !stack.isEmpty else { return result }
                stack[stack.count - 1].childResults.append(result)
                continue
            }

            // Push the next child (reverse order so they're processed front-to-back).
            let child = children[children.count - 1 - frame.nextChild]
            stack.append(Frame(node: frame.node, nextChild: frame.nextChild + 1, childResults: frame.childResults))
            stack.append(Frame(node: child))
        }

        fatalError("unreachable — the root node should have returned above")
    }

    /// Produces the Markdown string for a single element once its children are fully converted.
    ///
    /// The standard cases (headings, bold, lists, etc.) mirror the original `convertNode` switch.
    /// List elements (`ul`, `ol`) and tables re-enter the iterative walk via ``convertNode(_:options:)``
    /// for each child element, which is safe because each call keeps its own heap stack and
    /// adds at most one CPU frame per list/table nesting level.
    private func tagResult(
        for el: Element,
        tag: String,
        inner: String,
        options: MarkdownOptions
    ) -> String {
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
            return "\n\n" + el.children().enumerated().map { i, li in
                "\(i + 1). " + convertNode(li, options: options).trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined(separator: "\n") + "\n\n"
        case "li": return inner
        case "a":
            if options.preserveLinks,
               let href = try? el.attr("abs:href"), !href.isEmpty {
                return "[\(inner)](\(href))"
            }
            return inner
        case "img":
            if options.preserveImages,
               let src = try? el.attr("abs:src"), !src.isEmpty {
                let alt = (try? el.attr("alt")) ?? ""
                return "![\(alt)](\(src))"
            }
            return ""
        case "table": return convertTable(el, options: options)
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
