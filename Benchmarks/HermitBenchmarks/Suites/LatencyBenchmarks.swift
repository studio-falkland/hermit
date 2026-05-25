import Benchmark
import Hermit
import Foundation

/// Registers concurrency-vs-latency benchmarks.
///
/// Each benchmark uses a dedicated ``SyntheticHTTPServer`` pre-started in
/// `Benchmark.setup` with a fixed per-response delay. On zero-latency loopback
/// concurrency barely matters; with artificial latency the throughput gap between
/// c=1 and c=16 becomes clearly visible, mirroring behaviour on real networks.
///
/// Latency servers are started once (not per-benchmark) so iterations reuse warm
/// connections and measure steady-state throughput rather than TCP handshake cost.
func latencyBenchmarks() {
    let latencyConfig = Benchmark.Configuration(
        warmupIterations: 1,
        maxDuration: .seconds(60),
        maxIterations: 10
    )

    for latencyMs in [10, 50] {
        for concurrency in [1, 8, 32, 128] {
            Benchmark(
                "latency/\(latencyMs)ms c=\(concurrency) (maxPages=20)",
                configuration: latencyConfig
            ) { benchmark in
                let port = latencyPorts[latencyMs]!
                let seed = URL(string: "http://127.0.0.1:\(port)/page/0")!
                var count = 0
                for try await _ in benchmarkHermit!.crawlStream(seed, configure: {
                    $0.maxPages = 20
                    $0.concurrency = concurrency
                }) { count += 1 }
                blackHole(count)
            }
        }
    }
}
