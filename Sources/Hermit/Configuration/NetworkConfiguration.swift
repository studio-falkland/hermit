import Foundation

/// Shared HTTP-level settings applied to every request.
///
/// `NetworkConfiguration` is embedded in both ``CrawlConfiguration`` and ``ScrapeConfiguration``.
/// Configure it via the `network` property on either of those types.
///
/// ```swift
/// let config = try CrawlConfiguration(
///     network: NetworkConfiguration(
///         userAgent: "MyBot/1.0",
///         timeout: 10,
///         headers: ["Authorization": "Bearer token"]
///     )
/// )
/// ```
public struct NetworkConfiguration: Sendable {
    /// The value sent in the `User-Agent` request header.
    ///
    /// Defaults to `"Hermit/1.0"`. Set this to identify your crawler to server operators.
    public let userAgent: String

    /// The maximum number of seconds to wait for a complete response before timing out.
    ///
    /// Defaults to `30` seconds. Must be finite and greater than 0.
    public let timeout: TimeInterval

    /// Additional HTTP headers to include on every request.
    ///
    /// These are merged with the headers Hermit sets automatically (`User-Agent`, `Accept-Encoding`).
    /// Manually set values take precedence.
    public let headers: [String: String]

    /// The maximum response body size in bytes that Hermit will read into memory.
    ///
    /// Responses larger than this limit will throw an error. Defaults to 10 MB.
    public let maxBodySize: UInt

    /// Creates a network configuration.
    ///
    /// - Parameters:
    ///   - userAgent: The `User-Agent` header value (default: `"Hermit/1.0"`).
    ///   - timeout: Request timeout in seconds (default: `30`). Must be finite and > 0.
    ///   - headers: Additional HTTP headers (default: `[:]`).
    ///   - maxBodySize: Maximum response body size in bytes (default: 10 MB).
    /// - Throws: ``HermitError/invalidConfiguration(_:)`` if any value is invalid.
    public init(
        userAgent: String = "Hermit/1.0",
        timeout: TimeInterval = 30,
        headers: [String: String] = [:],
        maxBodySize: UInt = 10 * 1024 * 1024
    ) throws {
        guard timeout > 0, timeout.isFinite else {
            throw HermitError.invalidConfiguration("network.timeout must be > 0 and finite")
        }
        guard maxBodySize > 0 else {
            throw HermitError.invalidConfiguration("network.maxBodySize must be > 0")
        }
        self.userAgent = userAgent
        self.timeout = timeout
        self.headers = headers
        self.maxBodySize = maxBodySize
    }

    /// The default network configuration.
    ///
    /// All values are valid defaults — this never throws.
    public static let `default`: NetworkConfiguration = {
        try! NetworkConfiguration()
    }()
}