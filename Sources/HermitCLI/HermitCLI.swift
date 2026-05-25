import ArgumentParser
import Foundation
import Hermit
import Logging

extension Logger.Level: @retroactive ExpressibleByArgument {}

@main
struct HermitCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hermit-cli",
        abstract: "Crawl a website and mirror its content to disk as Markdown."
    )

    @Argument(help: "The seed URL to start crawling from.")
    var url: String

    @Option(name: .shortAndLong, help: "Directory to write the mirrored site into.")
    var output: String = "site"

    @Option(help: "Maximum link depth to follow from the seed URL.")
    var maxDepth: Int = 3

    @Option(help: "Maximum total number of pages to crawl.")
    var maxPages: Int?

    @Option(help: "Number of concurrent requests.")
    var concurrency: Int = 8

    @Option(help: "Maximum requests per second.")
    var rateLimit: Double?

    @Flag(help: "Also crawl subdomains of the seed host.")
    var includeSubdomains: Bool = false

    @Flag(help: "Do not fetch or respect robots.txt.")
    var ignoreRobotsTxt: Bool = false

    @Option(name: .long, help: "CSS selector for elements to strip before Markdown conversion. Repeatable.")
    var denyTag: [String] = ["nav", "header", "footer", "aside"]

    @Option(help: "Log level: trace, debug, info, notice, warning, error, critical.")
    var logLevel: Logger.Level = .warning

    func run() async throws {
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = logLevel
            return handler
        }

        guard let seedURL = URL(string: url) else {
            throw ValidationError("'\(url)' is not a valid URL.")
        }

        let outputDir = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        print("Crawling \(seedURL)…")
        print("Output  → \(outputDir.path)\n")

        let start = Date()
        var count = 0

        try await Hermit.withHermit { hermit in
            let stream = hermit.crawlAndScrape(
                seedURL,
                crawl: { config in
                    config.maxDepth = maxDepth
                    if let maxPages { config.maxPages = maxPages }
                    config.concurrency = concurrency
                    config.requestsPerSecond = rateLimit
                    config.includeSubdomains = includeSubdomains
                    config.respectRobotsTxt = !ignoreRobotsTxt
                },
                scrape: { config in
                    config.outputMarkdown = true
                    config.markdown.denyTags = denyTag
                }
            )

            for try await page in stream {
                print("Scraping " + page.url.path());
                let destination = markdownPath(for: page.url, in: outputDir)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let content = page.markdown ?? page.html
                try content.write(to: destination, atomically: true, encoding: .utf8)

                let relative = String(destination.path.dropFirst(outputDir.path.count + 1))
                let pagePath = page.url.path.isEmpty ? "/" : page.url.path
                print("  ✓ \(pagePath)  →  \(relative)")
                count += 1
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        print("\nDone — \(count) page\(count == 1 ? "" : "s") written in \(String(format: "%.1f", elapsed))s")
    }

    /// Derives a `.md` output path from a page URL, mirroring the URL's path structure.
    ///
    /// - `/`             → `index.md`
    /// - `/about`        → `about.md`
    /// - `/about/`       → `about/index.md`
    /// - `/blog/post-1`  → `blog/post-1.md`
    private func markdownPath(for url: URL, in directory: URL) -> URL {
        let path = url.path
        guard !path.isEmpty, path != "/" else {
            return directory.appendingPathComponent("index.md")
        }

        let trimmed = String(path.drop(while: { $0 == "/" }))
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !components.isEmpty else {
            return directory.appendingPathComponent("index.md")
        }

        var result = directory

        if path.hasSuffix("/") {
            for component in components {
                result = result.appendingPathComponent(component)
            }
            return result.appendingPathComponent("index.md")
        } else {
            for component in components.dropLast() {
                result = result.appendingPathComponent(component)
            }
            return result.appendingPathComponent(components[components.endIndex - 1] + ".md")
        }
    }
}
