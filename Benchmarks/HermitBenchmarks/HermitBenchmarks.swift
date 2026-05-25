import Benchmark
import Hermit
import Foundation

// MARK: - Shared state
//
// Written once in Benchmark.setup (before any benchmark runs) and read by all
// benchmark closures. In Swift 5.9's default concurrency mode (minimal), plain
// global vars in executable targets do not produce Sendability diagnostics.

var benchmarkServer: SyntheticHTTPServer?
var benchmarkPort: Int = 0
var benchmarkSeedURL: URL = URL(string: "http://127.0.0.1:8080/page/0")!
var benchmarkHermit: Hermit?

// One pre-started server per artificial latency tier (ms → server).
var latencyServers: [Int: SyntheticHTTPServer] = [:]
// ms → bound port, looked up by latency benchmark closures.
var latencyPorts: [Int: Int] = [:]

// Pre-built URL slices for scrape benchmarks (avoids URL construction in the hot loop).
var benchmarkScrapeURLs25: [URL] = []
var benchmarkScrapeURLs100: [URL] = []

// Pre-generated HTML fixtures for parse benchmarks.
// Port is only known after setup, so these are initialised there.
var benchmarkSmallHTML: String = ""
var benchmarkLargeHTML: String = ""
var benchmarkBaseURL: URL = URL(string: "http://127.0.0.1:8080/page/0")!

// Stateless converter; creating it at module level avoids per-iteration allocation.
let benchmarkConverter = DefaultMarkdownConverter()

// MARK: - Entry point
//
// The BenchmarkPlugin generates a main.swift that calls `benchmarks()`, which
// registers all Benchmark instances and wires up global setup/teardown hooks.
// Do NOT add @main or a main.swift to this target.

let benchmarks: @Sendable () -> Void = {
    // Set safe defaults: wall clock + throughput only.
    // Excludes .mallocCountTotal (requires jemalloc) and .instructions
    // (requires kernel perf counters) — both can hang BenchmarkTool on macOS
    // when system jemalloc and the target OS version don't match.
    Benchmark.defaultConfiguration = .init(
        warmupIterations: 3,
        maxDuration: .seconds(5),
        maxIterations: 1_000
    )

    Benchmark.setup = {
        // branching=5, depth=4 → 781 total pages; larger than any maxPages we use.
        let graph = PageGraph.tree(branching: 5, depth: 4)

        let server = SyntheticHTTPServer(graph: graph)
        benchmarkPort = try await server.start()
        benchmarkServer = server

        benchmarkSeedURL = URL(string: "http://127.0.0.1:\(benchmarkPort)/page/0")!

        // Start one latency server per tier so every latency benchmark closure can
        // reuse warm connections across iterations.
        for ms in [10, 50] {
            let ls = SyntheticHTTPServer.withLatency(graph: graph, milliseconds: ms)
            let port = try await ls.start()
            latencyServers[ms] = ls
            latencyPorts[ms] = port
        }

        // Pre-build scrape URL lists.
        benchmarkScrapeURLs25 = (0..<25).map {
            URL(string: "http://127.0.0.1:\(benchmarkPort)/page/\($0)")!
        }
        benchmarkScrapeURLs100 = (0..<100).map {
            URL(string: "http://127.0.0.1:\(benchmarkPort)/page/\($0)")!
        }

        // Pre-generate HTML fixtures for the parse benchmarks.
        benchmarkSmallHTML = PageGraph.tree(branching: 5, depth: 1, bodyParagraphs: 5)
            .html(for: 0, port: benchmarkPort)
        benchmarkLargeHTML = PageGraph.tree(branching: 5, depth: 1, bodyParagraphs: 50)
            .html(for: 0, port: benchmarkPort)
        benchmarkBaseURL = URL(string: "http://127.0.0.1:\(benchmarkPort)/page/0")!

        benchmarkHermit = Hermit()
    }

    Benchmark.teardown = {
        try await benchmarkHermit?.shutdown()
        benchmarkHermit = nil
        for server in latencyServers.values { try await server.shutdown() }
        latencyServers = [:]
        try await benchmarkServer?.shutdown()
        benchmarkServer = nil
    }

    // Register all suites.
    crawlBenchmarks()
    scrapeBenchmarks()
    parseBenchmarks()
    latencyBenchmarks()
}
