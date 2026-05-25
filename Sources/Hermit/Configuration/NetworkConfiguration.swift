import Foundation

/// Shared HTTP-level settings applied to every request.
///
/// `NetworkConfiguration` is embedded in both ``CrawlConfiguration`` and ``ScrapeConfiguration``.
/// Configure it via the `network` property on either of those types.
///
/// ```swift
/// hermit.crawl("https://example.com") {
///     $0.network.userAgent = "MyBot/1.0"
///     $0.network.timeout = 10
///     $0.network.headers = ["Authorization": "Bearer token"]
/// }
/// ```
public struct NetworkConfiguration: Sendable {
    /// The value sent in the `User-Agent` request header.
    ///
    /// Defaults to `"Hermit/1.0"`. Set this to identify your crawler to server operators.
    public var userAgent: String = "Hermit/1.0"

    /// The maximum number of seconds to wait for a complete response before timing out.
    ///
    /// Defaults to `30` seconds.
    public var timeout: TimeInterval = 30

    /// Additional HTTP headers to include on every request.
    ///
    /// These are merged with the headers Hermit sets automatically (`User-Agent`, `Accept-Encoding`).
    /// Manually set values take precedence.
    public var headers: [String: String] = [:]

    /// The maximum response body size in bytes that Hermit will read into memory.
    ///
    /// Responses larger than this limit will throw an error. Defaults to 10 MB.
    public var maxBodySize: Int = 10 * 1024 * 1024

    /// The default network configuration.
    public static let `default` = NetworkConfiguration()
}
