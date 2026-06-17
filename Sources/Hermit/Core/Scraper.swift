import Foundation
import SwiftSoup
import NIOHTTP1
import Logging

private let logger = Logger(label: "Hermit.Scraper")

/// Fetches pages and converts them into ``ScrapedPage`` values.
///
/// `Scraper` handles both single-page scraping and concurrent batch scraping via a `TaskGroup`.
/// It is composed by ``Hermit`` and is not intended to be used directly.
struct Scraper: Sendable {
    let httpClient: HermitHTTPClient

    /// Optional rate limiter; `nil` means no throttling is applied.
    let rateLimiter: RateLimiter?

    let markdownConverter: any MarkdownConverter

    /// Post-processing steps run in order on every page after initial parsing.
    let processors: [any PageProcessor]

    /// Fetches and parses a single page.
    ///
    /// - Parameters:
    ///   - url: The URL to fetch.
    ///   - configuration: Scrape options including Markdown conversion and CSS extractions.
    /// - Returns: A fully built ``ScrapedPage``.
    /// - Throws: ``HermitError`` on network or parsing failure.
    func scrape(_ url: URL, configuration: ScrapeConfiguration) async throws -> ScrapedPage {
        logger.debug("Scraping URL", metadata: ["url": "\(url)"])
        try await rateLimiter?.acquire()
        let result = try await httpClient.fetch(url, mode: .scrape)
        logger.debug("Fetch complete", metadata: ["url": "\(url)", "status": "\(result.statusCode)", "bytes": "\(result.body?.utf8.count ?? 0)"])
        guard let body = result.body else {
            // This branch is unreachable in practice since .scrape mode always populates body,
            // but is included for exhaustive guard coverage.
            throw HermitError.parsing(url, underlying: MissingBodyError())
        }
        return try await build(url: url, statusCode: result.statusCode, html: body, headers: result.headers, configuration: configuration)
    }

    /// Builds a ``ScrapedPage`` from pre-fetched HTML, skipping the HTTP request.
    ///
    /// Used by ``Hermit/crawlAndScrape(_:crawl:scrape:)`` to reuse bodies already collected
    /// during the crawl phase, halving the number of network round-trips.
    func scrapeFromHTML(
        _ url: URL,
        html: String,
        statusCode: Int,
        headers: HTTPHeaders,
        configuration: ScrapeConfiguration
    ) async throws -> ScrapedPage {
        return try await build(url: url, statusCode: statusCode, html: html, headers: headers, configuration: configuration)
    }

    /// Scrapes a collection of URLs concurrently and streams results as they complete.
    ///
    /// All URLs are dispatched simultaneously inside a `TaskGroup`. Results arrive in
    /// completion order, not input order.
    ///
    /// - Parameters:
    ///   - urls: The URLs to scrape.
    ///   - configuration: Scrape options applied uniformly to every page.
    func scrapeStream(
        urls: some Collection<URL> & Sendable,
        configuration: ScrapeConfiguration
    ) -> AsyncThrowingStream<ScrapedPage, Error> {
        logger.debug("Starting scrape stream", metadata: ["urlCount": "\(urls.count)"])
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await withThrowingTaskGroup(of: ScrapedPage.self) { group in
                        // Dispatch all scrape tasks at once; actual concurrency is governed
                        // by the cooperative thread pool and the optional rate limiter.
                        for url in urls {
                            group.addTask { try await self.scrape(url, configuration: configuration) }
                        }
                        for try await page in group {
                            continuation.yield(page)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Builds a ``ScrapedPage`` from a raw HTML response body.
    ///
    /// Parsing, optional Markdown conversion, CSS extractions, and the processor pipeline
    /// all happen here in sequence.
    private func build(
        url: URL,
        statusCode: Int,
        html: String,
        headers: HTTPHeaders,
        configuration: ScrapeConfiguration
    ) async throws -> ScrapedPage {
        // Parse the HTML into a SwiftSoup document once; all subsequent operations reuse it.
        let doc = try HTMLParser.parse(html, url: url)
        logger.trace("HTML parsed", metadata: ["url": "\(url)"])
        let metadata = HTMLParser.extractMetadata(from: doc, base: url)
        logger.trace("Metadata extracted", metadata: ["url": "\(url)", "title": "\(metadata.title ?? "nil")"])

        // Run each named CSS selector and capture the first matched element's text content.
        // Extractions run before markdown conversion so the document is unmodified when queried.
        var extractions: [String: String] = [:]
        for (key, selector) in configuration.extractions {
            logger.trace("Running extraction", metadata: ["url": "\(url)", "key": "\(key)", "selector": "\(selector)"])
            extractions[key] = try? doc.select(selector).first()?.text()
        }

        // Pass the already-parsed document to avoid a second SwiftSoup parse for markdown.
        // Markdown conversion is optional and potentially expensive — only run it when requested.
        let markdown: String? = configuration.outputMarkdown
            ? try markdownConverter.convert(document: doc, baseURL: url, options: configuration.markdown)
            : nil

        var page = ScrapedPage(
            url: url,
            statusCode: statusCode,
            html: html,
            markdown: markdown,
            metadata: metadata,
            extractions: extractions,
            responseHeaders: headers
        )

        // Run the page through each processor in order, passing the output of one into the next.
        for processor in processors {
            logger.trace("Running processor", metadata: ["url": "\(url)", "processor": "\(type(of: processor))"])
            page = try await processor.process(page)
        }
        logger.debug("Scrape complete", metadata: ["url": "\(url)", "hasMarkdown": "\(page.markdown != nil)", "extractions": "\(page.extractions.count)"])
        return page
    }
}

/// Sentinel error used when `FetchResult.body` is `nil` in scrape mode.
///
/// This should never occur in practice — `.scrape` mode always populates the body field.
private struct MissingBodyError: Error {}
