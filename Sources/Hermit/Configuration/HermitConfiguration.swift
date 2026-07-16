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
        ///
        /// Redirect responses (3xx) are followed by default, up to a maximum of 5 hops and 5
        /// redirect cycles. Callers that need different behaviour should construct their own
        /// ``Hermit`` with a custom `HTTPClient`.
        var httpClientConfiguration: HTTPClient.Configuration {
                HTTPClient.Configuration(
                    redirectConfiguration: .follow(max: 5, allowCycles: true),
                    connectionPool: .init(
                        idleTimeout: .seconds(Int64(connectionPoolIdleTimeout)),
                        concurrentHTTP1ConnectionsPerHostSoftLimit: connectionsPerHostSoftLimit
                    ),
                    decompression: .enabled(limit: .size(10 * 1024 * 1024))
                )
            }
}
