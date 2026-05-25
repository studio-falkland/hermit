import AsyncHTTPClient
import NIOCore
import Foundation
import Logging

private let logger = Logger(label: "Hermit.HTTPClient")

/// Controls what data is extracted from a fetched response.
enum FetchMode {
    /// Extract only outbound links from the response body. The raw HTML is discarded.
    ///
    /// Used during crawl-only operations to minimise allocations — there is no need to
    /// keep the full response string in memory when only links are needed.
    case crawl

    /// Retain the full response body string for downstream parsing and conversion.
    ///
    /// Used during scrape operations where the caller needs the HTML content.
    case scrape
}

/// The processed result of a single HTTP fetch.
struct FetchResult {
    /// The final URL of the response (after any redirects).
    let url: URL

    /// The HTTP response status code.
    let statusCode: Int

    /// The decoded response body, or `nil` when ``FetchMode/crawl`` was used.
    let body: String?

    /// Normalised absolute URLs extracted from `<a href>` tags.
    ///
    /// Non-empty only when ``FetchMode/crawl`` was used.
    let links: [URL]
}

/// A lightweight wrapper around `AsyncHTTPClient.HTTPClient` that handles request
/// construction, response body collection, and mode-specific processing.
///
/// `HermitHTTPClient` is a value type. The underlying `HTTPClient` is a reference type
/// owned by ``Hermit`` and shared across all operations — never create one outside of
/// ``Hermit/init(configuration:eventLoopGroupProvider:processors:markdownConverter:)``.
struct HermitHTTPClient: Sendable {
    private let client: HTTPClient
    private let config: NetworkConfiguration

    init(client: HTTPClient, config: NetworkConfiguration) {
        self.client = client
        self.config = config
    }

    /// Fetches a URL and returns a ``FetchResult`` appropriate for the given mode.
    ///
    /// In `.crawl` mode the response body is parsed for links then discarded, keeping
    /// peak memory usage low. In `.scrape` mode the full body is preserved for the caller.
    ///
    /// - Parameters:
    ///   - url: The URL to fetch.
    ///   - mode: Controls whether the full body or only outbound links are returned.
    /// - Returns: A ``FetchResult`` containing the status, body (if applicable), and links.
    /// - Throws: An error from AsyncHTTPClient if the request fails.
    func fetch(_ url: URL, mode: FetchMode) async throws -> FetchResult {
        // Build the request, applying the user agent and any caller-supplied headers.
        var request = HTTPClientRequest(url: url.absoluteString)
        logger.debug("Fetching URL", metadata: ["url": "\(url)", "mode": "\(mode)"])
        request.headers.add(name: "User-Agent", value: config.userAgent)
        // Advertise only the encodings NIO can decompress (gzip, deflate).
        // Brotli is intentionally omitted — swift-nio-extras does not support it,
        // so advertising "br" would cause servers to send bytes we cannot decode.
        request.headers.add(name: "Accept-Encoding", value: "gzip, deflate")
        logger.trace("Request headers set", metadata: ["url": "\(url)", "userAgent": "\(config.userAgent)"])
        for (key, value) in config.headers {
            request.headers.add(name: key, value: value)
        }

        let response = try await client.execute(
            request,
            timeout: .seconds(Int64(config.timeout))
        )

        switch mode {
        case .crawl:
            // Collect up to 2 MB — enough for any realistic HTML page.
            // The body is returned so callers that need it (e.g. crawlAndScrape) can reuse it
            // without a second HTTP request.
            let buffer = try await response.body.collect(upTo: 2 * 1024 * 1024)
            let body = String(buffer: buffer)
            logger.trace("Crawl response received", metadata: ["url": "\(url)", "status": "\(response.status.code)", "bytes": "\(buffer.readableBytes)"])
            let links = HTMLParser.extractLinks(from: body, base: url)
            logger.debug("Crawl fetch complete", metadata: ["url": "\(url)", "status": "\(response.status.code)", "links": "\(links.count)"])
            return FetchResult(url: url, statusCode: Int(response.status.code), body: body, links: links)

        case .scrape:
            // Collect up to the configured limit so callers get the full page content.
            let buffer = try await response.body.collect(upTo: config.maxBodySize)
            let body = String(buffer: buffer)
            logger.debug("Scrape fetch complete", metadata: ["url": "\(url)", "status": "\(response.status.code)", "bytes": "\(buffer.readableBytes)"])
            return FetchResult(url: url, statusCode: Int(response.status.code), body: body, links: [])
        }
    }
}
