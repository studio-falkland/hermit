import NIOCore
import NIOPosix
import NIOHTTP1

// MARK: - Server

/// A minimal in-process HTTP/1.1 server that serves synthetic HTML pages on-demand.
///
/// Bind once with ``start()`` at the beginning of the benchmark run, pass the returned
/// port to each benchmark closure, then call ``shutdown()`` at the end. The server runs
/// on its own `MultiThreadedEventLoopGroup` so it does not share threads with the
/// `async-http-client` singleton group.
final class SyntheticHTTPServer: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let graph: PageGraph
    private let latency: TimeAmount
    // Written once in start(), read-only thereafter.
    private var serverChannel: (any Channel)?
    private(set) var port: Int = 0

    /// - Parameters:
    ///   - graph: The page graph used to generate HTML on-demand.
    ///   - latency: Fixed artificial delay added before each response is written.
    ///     Use `.zero` (the default) for no delay, or e.g. `.milliseconds(50)` to
    ///     simulate network RTT. The delay uses `EventLoop.scheduleTask(in:)` —
    ///     no thread is ever blocked.
    init(graph: PageGraph, latency: TimeAmount = .zero) {
        self.graph = graph
        self.latency = latency
        // Two threads are more than enough for loopback I/O bounded by the client.
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    /// Convenience factory for benchmarks that create latency-injected servers
    /// without importing `NIOCore` to spell `TimeAmount`.
    static func withLatency(graph: PageGraph, milliseconds: Int) -> SyntheticHTTPServer {
        SyntheticHTTPServer(graph: graph, latency: .milliseconds(Int64(milliseconds)))
    }

    /// Binds to a random loopback port and starts accepting connections.
    ///
    /// - Returns: The OS-assigned port number.
    func start() async throws -> Int {
        let portBox = PortBox()
        let graph = self.graph

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [latency] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        SyntheticPageHandler(graph: graph, portBox: portBox, latency: latency)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()

        guard let address = channel.localAddress, let boundPort = address.port else {
            try await channel.close().get()
            throw BenchmarkServerError.bindFailed
        }

        // Safe: portBox is only read by SyntheticPageHandler after connections arrive,
        // which is after this line executes.
        portBox.port = boundPort
        serverChannel = channel
        port = boundPort
        return boundPort
    }

    /// Closes the server channel and shuts down the event loop group.
    func shutdown() async throws {
        try await serverChannel?.close().get()
        try await group.shutdownGracefully()
    }
}

// MARK: - Internal helpers

enum BenchmarkServerError: Error {
    case bindFailed
}

/// Shared port reference written once by ``SyntheticHTTPServer/start()`` before
/// the first connection arrives, then read-only by ``SyntheticPageHandler``.
final class PortBox: @unchecked Sendable {
    var port: Int = 0
}

// MARK: - Channel handler

/// NIO channel handler that services individual HTTP/1.1 requests.
///
/// Buffers the request `head` part and fires a response when the `end` part arrives.
/// Response bodies are generated on-demand from ``PageGraph`` — no file I/O, no caching.
private final class SyntheticPageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let graph: PageGraph
    private let portBox: PortBox
    private let latency: TimeAmount
    private var pendingHead: HTTPRequestHead?

    init(graph: PageGraph, portBox: PortBox, latency: TimeAmount) {
        self.graph = graph
        self.portBox = portBox
        self.latency = latency
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            pendingHead = head
        case .body:
            break
        case .end:
            guard let head = pendingHead else { return }
            respond(context: context, to: head)
            pendingHead = nil
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - Response dispatch

    private func respond(context: ChannelHandlerContext, to head: HTTPRequestHead) {
        let path = head.uri.components(separatedBy: "?").first ?? head.uri
        let version = head.version

        if latency == .zero {
            dispatch(context: context, path: path, version: version)
        } else {
            // scheduleTask runs on the event loop — no thread is ever blocked.
            context.eventLoop.scheduleTask(in: latency) {
                self.dispatch(context: context, path: path, version: version)
            }
        }
    }

    private func dispatch(context: ChannelHandlerContext, path: String, version: HTTPVersion) {
        switch path {
        case "/":
            writeRedirect(context: context, to: "/page/0", version: version)

        case "/robots.txt":
            writeText(
                context: context,
                status: .ok,
                contentType: "text/plain",
                body: "User-agent: *\nAllow: /\n",
                version: version
            )

        default:
            if path.hasPrefix("/page/"),
               let index = Int(path.dropFirst("/page/".count)),
               index >= 0, index < graph.totalPages {
                writeHTML(
                    context: context,
                    body: graph.html(for: index, port: portBox.port),
                    version: version
                )
            } else if path.hasPrefix("/links/"),
                      let count = Int(path.dropFirst("/links/".count)),
                      count >= 0 {
                writeHTML(
                    context: context,
                    body: graph.htmlWithLinks(count: count, port: portBox.port),
                    version: version
                )
            } else {
                writeText(
                    context: context,
                    status: .notFound,
                    contentType: "text/html; charset=utf-8",
                    body: "<html><body><h1>404 Not Found</h1></body></html>",
                    version: version
                )
            }
        }
    }

    // MARK: - Write helpers

    private func writeRedirect(
        context: ChannelHandlerContext,
        to location: String,
        version: HTTPVersion
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "location", value: location)
        headers.add(name: "content-length", value: "0")
        let responseHead = HTTPResponseHead(version: version, status: .movedPermanently, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        let emptyBuffer = context.channel.allocator.buffer(capacity: 0)
        context.write(wrapOutboundOut(.body(.byteBuffer(emptyBuffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func writeHTML(context: ChannelHandlerContext, body: String, version: HTTPVersion) {
        writeText(
            context: context,
            status: .ok,
            contentType: "text/html; charset=utf-8",
            body: body,
            version: version
        )
    }

    private func writeText(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        contentType: String,
        body: String,
        version: HTTPVersion
    ) {
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)

        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: "\(buffer.readableBytes)")
        headers.add(name: "connection", value: "keep-alive")

        let responseHead = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
