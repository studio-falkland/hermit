import Benchmark
import Hermit
import Foundation

/// Registers parser and converter micro-benchmarks.
///
/// These benchmarks call public library types directly — no HTTP round-trips.
/// HTML fixtures are pre-generated in `Benchmark.setup` so only the parse /
/// conversion work is measured.
func parseBenchmarks() {
    // CPU-bound: run more iterations in the same wall-clock window.
    let parseConfig = Benchmark.Configuration(
        warmupIterations: 5,
        maxDuration: .seconds(5),
        maxIterations: 2_000
    )

    // Markdown conversion — small document (~1 KB, 5 paragraphs + 5 links).
    Benchmark("parse/markdown-small", configuration: parseConfig) { benchmark in
        let md = try benchmarkConverter.convert(
            html: benchmarkSmallHTML,
            baseURL: benchmarkBaseURL,
            options: .default
        )
        blackHole(md)
    }

    // Markdown conversion — large document (~20 KB, 50 paragraphs + 5 links).
    Benchmark("parse/markdown-large", configuration: parseConfig) { benchmark in
        let md = try benchmarkConverter.convert(
            html: benchmarkLargeHTML,
            baseURL: benchmarkBaseURL,
            options: .default
        )
        blackHole(md)
    }

    // Full scrape pipeline over the network: fetch → parse → metadata → Markdown → extractions.
    // Uses a warm connection so network overhead is minimal; measures CPU pipeline cost.
    let scrapeConfig = Benchmark.Configuration(
        warmupIterations: 5,
        maxDuration: .seconds(10),
        maxIterations: 500
    )

    Benchmark("parse/scrape-with-extractions", configuration: scrapeConfig) { benchmark in
        let page = try await benchmarkHermit!.scrape(benchmarkScrapeURLs25[0], configure: {
            $0.outputMarkdown = true
            $0.extractions = [
                "title": "h1",
                "description": "meta[name=description]",
                "firstLink": "a:first-child",
            ]
        })
        blackHole(page.extractions)
        blackHole(page.markdown)
    }
}
