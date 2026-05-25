import Benchmark
import Hermit
import Foundation

/// Registers crawl throughput benchmarks.
///
/// Each scenario crawls the synthetic server up to a `maxPages` ceiling.
/// The shared `benchmarkHermit` instance keeps the HTTP connection pool warm
/// across iterations, reflecting steady-state throughput rather than cold-start cost.
func crawlBenchmarks() {
    // Medium crawl needs a larger time window — each iteration takes ~40 ms.
    let mediumConfig = Benchmark.Configuration(
        warmupIterations: 2,
        maxDuration: .seconds(20),
        maxIterations: 50
    )

    let sweepConfig = Benchmark.Configuration(
        warmupIterations: 2,
        maxDuration: .seconds(5),
        maxIterations: 200
    )

    Benchmark("crawl/tiny (maxPages=13, c=8)") { benchmark in
        var count = 0
        for try await _ in benchmarkHermit!.crawlStream(benchmarkSeedURL, configure: {
            $0.maxPages = 13
            $0.concurrency = 8
        }) { count += 1 }
        blackHole(count)
    }

    Benchmark("crawl/small (maxPages=50, c=8)") { benchmark in
        var count = 0
        for try await _ in benchmarkHermit!.crawlStream(benchmarkSeedURL, configure: {
            $0.maxPages = 50
            $0.concurrency = 8
        }) { count += 1 }
        blackHole(count)
    }

    Benchmark("crawl/medium (maxPages=200, c=8)", configuration: mediumConfig) { benchmark in
        var count = 0
        for try await _ in benchmarkHermit!.crawlStream(benchmarkSeedURL, configure: {
            $0.maxPages = 200
            $0.concurrency = 8
        }) { count += 1 }
        blackHole(count)
    }

    // Concurrency sweep — same page budget, varying parallelism.
    for concurrency in [1, 4, 8, 16] {
        Benchmark("crawl/c=\(concurrency) (maxPages=50)", configuration: sweepConfig) { benchmark in
            var count = 0
            for try await _ in benchmarkHermit!.crawlStream(benchmarkSeedURL, configure: {
                $0.maxPages = 50
                $0.concurrency = concurrency
            }) { count += 1 }
            blackHole(count)
        }
    }
}
