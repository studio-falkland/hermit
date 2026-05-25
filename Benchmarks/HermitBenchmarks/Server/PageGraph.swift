import Foundation

/// A deterministic k-ary tree of synthetic pages, addressed by BFS index.
///
/// Page 0 is the root. Page `n`'s children live at indices
/// `[n*branching+1 ..< n*branching+branching+1]`, clamped to `totalPages`.
/// This gives a perfectly balanced tree where every crawl against the synthetic
/// server visits exactly the same URL set in the same order — fully reproducible.
struct PageGraph: Sendable {
    /// Links emitted on every non-leaf page.
    let branching: Int

    /// Total number of nodes (pages) in the tree, including the root.
    let totalPages: Int

    /// Number of filler `<p>` elements written into each page body.
    /// Increase this to benchmark parser behaviour on larger HTML payloads.
    let bodyParagraphs: Int

    // MARK: - Factory

    /// Creates a graph representing a complete k-ary tree of the given depth.
    ///
    /// - Parameters:
    ///   - branching: Number of child links per non-leaf page.
    ///   - depth: Maximum depth from the root (0 = single page, no children).
    ///   - bodyParagraphs: Filler paragraphs per page (default: 0).
    static func tree(branching: Int, depth: Int, bodyParagraphs: Int = 0) -> PageGraph {
        var total = 0
        var power = 1
        for _ in 0...depth {
            total += power
            power *= branching
        }
        return PageGraph(branching: branching, totalPages: total, bodyParagraphs: bodyParagraphs)
    }

    // MARK: - Graph queries

    /// Child page indices of the given page, or `[]` for leaf pages.
    func children(of index: Int) -> [Int] {
        let first = index * branching + 1
        guard first < totalPages else { return [] }
        return Array(first..<min(first + branching, totalPages))
    }

    /// Seed URL for crawling this graph via a local server on `port`.
    func seedURL(port: Int) -> URL {
        // Force-unwrap: the URL template is always valid given a valid port integer.
        URL(string: "http://127.0.0.1:\(port)/page/0")!
    }

    // MARK: - HTML generation

    /// Generates deterministic HTML for the page at `index`.
    ///
    /// Links are absolute `http://127.0.0.1:{port}/page/{child}` URLs so the
    /// crawler's link normalisation produces the same results as the graph math.
    func html(for index: Int, port: Int) -> String {
        let childLinks = children(of: index)
            .map { child in
                #"<a href="http://127.0.0.1:\#(port)/page/\#(child)">Page \#(child)</a>"#
            }
            .joined(separator: "\n")

        let filler = (0..<bodyParagraphs)
            .map { i in
                "<p>Benchmark filler paragraph \(i) for page \(index). " +
                "Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>"
            }
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <title>Synthetic Page \(index)</title>
            <meta name="description" content="Benchmark page \(index) of \(totalPages).">
        </head>
        <body>
        <h1>Page \(index)</h1>
        <p>Synthetic page \(index) with \(children(of: index).count) outbound link(s).</p>
        \(filler)
        \(childLinks)
        </body>
        </html>
        """
    }

    /// Generates HTML with exactly `linkCount` outbound links, all pointing to `/page/0`.
    ///
    /// Used by parse benchmarks to isolate link-extraction cost at different link densities.
    func htmlWithLinks(count linkCount: Int, port: Int) -> String {
        let links = (0..<linkCount)
            .map { i in
                #"<a href="http://127.0.0.1:\#(port)/page/\#(i % totalPages)">Link \#(i)</a>"#
            }
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <title>Link-density benchmark page</title>
            <meta name="description" content="Page with \(linkCount) links for parse benchmarking.">
        </head>
        <body>
        <h1>Link-density page</h1>
        <p>This page has \(linkCount) outbound links.</p>
        \(links)
        </body>
        </html>
        """
    }
}
