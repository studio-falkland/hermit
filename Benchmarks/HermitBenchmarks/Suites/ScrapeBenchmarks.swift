import Benchmark
import Hermit
import Foundation

/// Registers scrape throughput benchmarks.
///
/// Unlike crawl, `scrapeStream` dispatches all URLs simultaneously with no
/// concurrency cap. These benchmarks isolate the cost of the full parse pipeline
/// (HTML → metadata → optional Markdown) with the network as a background constant.
func scrapeBenchmarks() {
    // Batch-100 and markdown conversion benchmarks are a bit slower.
    let heavyConfig = Benchmark.Configuration(
        warmupIterations: 2,
        maxDuration: .seconds(10),
        maxIterations: 200
    )

    Benchmark("scrape/batch-25") { benchmark in
        var count = 0
        for try await page in benchmarkHermit!.scrapeStream(benchmarkScrapeURLs25) {
            blackHole(page.metadata)
            count += 1
        }
        blackHole(count)
    }

    Benchmark("scrape/batch-100", configuration: heavyConfig) { benchmark in
        var count = 0
        for try await page in benchmarkHermit!.scrapeStream(benchmarkScrapeURLs100) {
            blackHole(page.metadata)
            count += 1
        }
        blackHole(count)
    }

    Benchmark("scrape/batch-25 + markdown") { benchmark in
        var count = 0
        for try await page in benchmarkHermit!.scrapeStream(
            benchmarkScrapeURLs25,
            configure: { $0.outputMarkdown = true }
        ) {
            blackHole(page.markdown)
            count += 1
        }
        blackHole(count)
    }

    Benchmark("scrape/batch-100 + markdown", configuration: heavyConfig) { benchmark in
        var count = 0
        for try await page in benchmarkHermit!.scrapeStream(
            benchmarkScrapeURLs100,
            configure: { $0.outputMarkdown = true }
        ) {
            blackHole(page.markdown)
            count += 1
        }
        blackHole(count)
    }

    // Single-page scrape — measures per-page baseline overhead (connect + parse).
    Benchmark("scrape/single") { benchmark in
        let page = try await benchmarkHermit!.scrape(benchmarkScrapeURLs25[0])
        blackHole(page.metadata)
    }
}
