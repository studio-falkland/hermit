import SwiftSoup
import Foundation
import Logging

private let logger = Logger(label: "Hermit.HTMLParser")

/// A namespace of static helpers for HTML parsing and data extraction.
///
/// All methods are pure functions — no state, no dependencies. They wrap SwiftSoup calls
/// with consistent error handling: ``extractLinks(from:base:)`` and ``extractMetadata(from:base:)``
/// swallow individual element errors gracefully (returning empty collections), while
/// ``parse(_:url:)`` propagates errors so the caller can decide how to handle a bad document.
enum HTMLParser {
    /// Extracts and normalises all outbound links from an HTML string.
    ///
    /// Only `<a href>` elements are considered. Relative URLs are resolved against `base`,
    /// and each result is passed through ``URL/normalized`` to strip fragments, lowercase
    /// the host, and remove default ports. Invalid or empty hrefs are silently dropped.
    ///
    /// - Parameters:
    ///   - html: The raw HTML string to parse.
    ///   - base: The base URL used to resolve relative links.
    /// - Returns: An array of normalised absolute URLs. May be empty if none are found.
    static func extractLinks(from html: String, base: URL) -> [URL] {
        logger.trace("Extracting links", metadata: ["base": "\(base)"])
        guard let doc = try? SwiftSoup.parse(html, base.absoluteString) else {
            logger.trace("Failed to parse HTML for link extraction", metadata: ["base": "\(base)"])
            return []
        }
        return extractLinks(from: doc, base: base)
    }

    /// Extracts and normalizes all anchor hrefs from an already-parsed document.
    ///
    /// Use this overload when a `Document` is already available to avoid re-parsing from HTML.
    static func extractLinks(from doc: Document, base: URL) -> [URL] {
        guard let anchors = try? doc.select("a[href]") else { return [] }
        let links: [URL] = anchors.compactMap { anchor in
            guard let href = try? anchor.attr("abs:href"), !href.isEmpty else { return nil }
            return URL(string: href)?.normalized
        }
        logger.trace("Links extracted", metadata: ["base": "\(base)", "count": "\(links.count)"])
        return links
    }

    /// Parses an HTML string into a SwiftSoup `Document`, throwing on failure.
    ///
    /// - Parameters:
    ///   - html: The raw HTML string.
    ///   - url: The page URL, used as the base for relative link resolution.
    /// - Returns: A parsed `Document`.
    /// - Throws: A SwiftSoup error if the HTML cannot be parsed.
    static func parse(_ html: String, url: URL) throws -> Document {
        logger.trace("Parsing HTML document", metadata: ["url": "\(url)"])
        return try SwiftSoup.parse(html, url.absoluteString)
    }

    /// Extracts structured metadata from an already-parsed document.
    ///
    /// Pulls title, description, canonical URL, Open Graph tags, all links, and all images.
    /// Individual failures (missing tags, invalid URLs) are silently skipped — a partial
    /// result is always returned rather than throwing.
    ///
    /// - Parameters:
    ///   - doc: The parsed SwiftSoup document.
    ///   - base: The page's URL, used to classify links as internal or external.
    /// - Returns: A ``PageMetadata`` struct populated with whatever could be extracted.
    static func extractMetadata(from doc: Document, base: URL) -> PageMetadata {
        logger.trace("Extracting metadata", metadata: ["base": "\(base)"])
        let title = try? doc.title()
        let description = try? doc.select("meta[name=description]").first()?.attr("content")
        let canonical = (try? doc.select("link[rel=canonical]").first()?.attr("href"))
            .flatMap { URL(string: $0) }

        // Collect all og:* meta tags into a flat dictionary keyed by property name.
        var og: [String: String] = [:]
        if let metas = try? doc.select("meta[property^=og:]") {
            for meta in metas {
                let property = (try? meta.attr("property")) ?? ""
                let content = (try? meta.attr("content")) ?? ""
                if !property.isEmpty, !content.isEmpty { og[property] = content }
            }
        }

        // Extract all anchor links, resolve them, and classify as internal or external.
        let links: [PageLink] = (try? doc.select("a[href]"))?.compactMap { el in
            guard let href = try? el.attr("abs:href"),
                  let url = URL(string: href)?.normalized else { return nil }
            let text = (try? el.text()) ?? ""
            let isExternal = url.host?.lowercased() != base.host?.lowercased()
            return PageLink(url: url, text: text, isExternal: isExternal)
        } ?? []

        // Extract all img elements with a valid src attribute.
        let images: [PageImage] = (try? doc.select("img[src]"))?.compactMap { el in
            guard let src = try? el.attr("abs:src"),
                  let url = URL(string: src) else { return nil }
            let alt = try? el.attr("alt")
            let width = (try? el.attr("width")).flatMap(Int.init)
            let height = (try? el.attr("height")).flatMap(Int.init)
            return PageImage(url: url, alt: alt?.isEmpty == false ? alt : nil, width: width, height: height)
        } ?? []

        logger.trace("Metadata extraction complete", metadata: ["base": "\(base)", "title": "\(title ?? "nil")", "links": "\(links.count)", "images": "\(images.count)"])
        return PageMetadata(
            title: title?.isEmpty == false ? title : nil,
            description: description?.isEmpty == false ? description : nil,
            canonicalURL: canonical,
            openGraph: og,
            links: links,
            images: images
        )
    }
}
