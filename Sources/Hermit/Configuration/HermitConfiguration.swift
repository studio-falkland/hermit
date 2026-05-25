import AsyncHTTPClient

/// Top-level configuration for the ``Hermit`` instance itself.
///
/// Controls the underlying `AsyncHTTPClient` connection pool. Pass an instance to
/// ``Hermit/init(configuration:eventLoopGroupProvider:processors:markdownConverter:)``.
///
/// ```swift
/// var config = HermitConfiguration()
/// config.connectionsPerHostSoftLimit = 4
/// let hermit = Hermit(configuration: config)
/// ```
public struct HermitConfiguration: Sendable {
    /// The number of seconds an idle connection is kept alive in the pool before being closed.
    ///
    /// Defaults to `30` seconds.
    public var connectionPoolIdleTimeout: Int = 30

    /// The soft cap on concurrent HTTP/1.1 connections to a single host.
    ///
    /// This limit is advisory — the pool may briefly exceed it under load. HTTP/2 connections
    /// are not affected; a single HTTP/2 connection multiplexes all requests to a host.
    /// Defaults to `8`.
    public var connectionsPerHostSoftLimit: Int = 8

    /// The default configuration.
    public static let `default` = HermitConfiguration()

    /// Builds the `HTTPClient.Configuration` value passed to AsyncHTTPClient.
    var httpClientConfiguration: HTTPClient.Configuration {
        HTTPClient.Configuration(
            connectionPool: .init(
                idleTimeout: .seconds(Int64(connectionPoolIdleTimeout)),
                concurrentHTTP1ConnectionsPerHostSoftLimit: connectionsPerHostSoftLimit
            ),
            // Decompress gzip and deflate responses transparently.
            // Ratio 25 guards against decompression bombs while allowing for the high
            // compression ratios that well-structured HTML regularly achieves (15-25x).
            // The real memory bound is enforced downstream by collect(upTo:).
            decompression: .enabled(limit: .ratio(25))
        )
    }
}
