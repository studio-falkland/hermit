import AsyncHTTPClient

/// Top-level configuration for the ``Hermit`` instance itself.
///
/// Controls the underlying `AsyncHTTPClient` connection pool. Pass an instance to
/// ``Hermit/init(configuration:eventLoopGroupProvider:processors:markdownConverter:)``.
///
/// ```swift
/// let config = try HermitConfiguration(connectionsPerHostSoftLimit: 4)
/// let hermit = Hermit(configuration: config)
/// ```
public struct HermitConfiguration: Sendable {
    /// The number of seconds an idle connection is kept alive in the pool before being closed.
    ///
    /// Defaults to `30` seconds.
    public let connectionPoolIdleTimeout: UInt

    /// The soft cap on concurrent HTTP/1.1 connections to a single host.
    ///
    /// This limit is advisory — the pool may briefly exceed it under load. HTTP/2 connections
    /// are not affected; a single HTTP/2 connection multiplexes all requests to a host.
    /// Defaults to `8`.
    public let connectionsPerHostSoftLimit: UInt

    /// Creates a hermit configuration.
    ///
    /// - Parameters:
    ///   - connectionPoolIdleTimeout: Idle connection timeout in seconds (default: `30`).
    ///   - connectionsPerHostSoftLimit: Soft cap on connections per host (default: `8`).
    /// - Throws: ``HermitError/invalidConfiguration(_:)`` if any value is invalid.
    public init(
        connectionPoolIdleTimeout: UInt = 30,
        connectionsPerHostSoftLimit: UInt = 64
    ) throws {
        guard connectionPoolIdleTimeout > 0 else {
            throw HermitError.invalidConfiguration("connectionPoolIdleTimeout must be > 0")
        }
        guard connectionsPerHostSoftLimit > 0 else {
            throw HermitError.invalidConfiguration("connectionsPerHostSoftLimit must be > 0")
        }
        self.connectionPoolIdleTimeout = connectionPoolIdleTimeout
        self.connectionsPerHostSoftLimit = connectionsPerHostSoftLimit
    }

    /// The default configuration.
    ///
    /// All values are valid defaults — this never throws.
    public static let `default`: HermitConfiguration = {
        try! HermitConfiguration()
    }()

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
                concurrentHTTP1ConnectionsPerHostSoftLimit: Int(connectionsPerHostSoftLimit)
            ),
            decompression: .enabled(limit: .size(10 * 1024 * 1024))
        )
    }
}
