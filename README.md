<p align="center">
    <img src="./Documentation/logo.svg" width="340" />
</p>

<p align="center">
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white" alt="Swift 5.9+"></a>
  <a href="https://swift.org/package-manager"><img src="https://img.shields.io/badge/SPM-compatible-4BC51D?logo=swift&logoColor=white" alt="SPM Compatible"></a>
  <a href="LICENSE.md"><img src="https://img.shields.io/github/license/studio-falkland/hermit" alt="License"></a>
</p>

## Introduction

`Hermit` is a pure Swift web crawling and scraping library for server-side use. It fetches HTML over HTTP and turns it into structured data or Markdown.

* Crawl a site to build a complete URL index
* Scrape pages into structured data, Markdown, or raw HTML
* Stream results with `AsyncThrowingStream` as pages complete
* Configure rate limiting, concurrency, domain policies, and URL filters

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/studio-falkland/hermit.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourTarget", dependencies: [
        .product(name: "Hermit", package: "hermit"),
    ]),
]
```

## API

All operations are methods on a `Hermit` instance. Use `withHermit` for scripts and one-off tasks — it shuts down the HTTP client automatically on exit, whether the body returns normally or throws:

```swift
try await Hermit.withHermit { hermit in
    // ...
}
```

For long-lived server processes that manage their own `EventLoopGroup`:

```swift
let hermit = Hermit(eventLoopGroupProvider: .shared(app.eventLoopGroup))
// ...
try await hermit.shutdown()
```

### Operations

| Method | Returns | Description |
|---|---|---|
| `crawl(_:configure:)` | `CrawlResult` | Crawl a site and collect all discovered URLs |
| `crawlStream(_:configure:)` | `AsyncThrowingStream<CrawledPage, Error>` | Stream pages as they are discovered |
| `scrape(_:configure:)` | `ScrapedPage` | Fetch and parse a single page |
| `scrapeStream(_:configure:)` | `AsyncThrowingStream<ScrapedPage, Error>` | Scrape a collection of URLs concurrently |
| `crawlAndScrape(_:crawl:scrape:)` | `AsyncThrowingStream<ScrapedPage, Error>` | Crawl a site then scrape every discovered page |

### Crawling

```swift
let result = try await hermit.crawl("https://docs.example.com") {
    $0.maxDepth = 4
    $0.maxPages = 1_000
    $0.concurrency = 16
    $0.requestsPerSecond = 10
    $0.denylist = ["/tag/", "/author/"]
}

print("\(result.visitedURLs.count) pages in \(result.duration)s")
```

Stream pages as they are discovered:

```swift
for try await page in hermit.crawlStream("https://example.com") {
    print("[\(page.depth)] \(page.url)")
}
```

### Scraping

```swift
let page = try await hermit.scrape("https://example.com/article") {
    $0.outputMarkdown = true
    $0.markdown.denyTags = ["nav", "footer", "aside"]
    $0.extractions = ["title": "h1", "author": ".byline"]
}

print(page.markdown!)
print(page.extractions["author"] ?? "unknown")
```

SwiftSoup is available directly on every `ScrapedPage` for ad-hoc queries:

```swift
let codeBlocks = try page.select("pre code")
```

Scrape a collection of URLs concurrently:

```swift
for try await page in hermit.scrapeStream(result.visitedURLs) {
    save(page)
}
```

### Crawl + Scrape

```swift
for try await page in hermit.crawlAndScrape(
    "https://docs.example.com",
    crawl: {
        $0.maxDepth = 3
        $0.allowlist = ["/docs/"]
    },
    scrape: {
        $0.outputMarkdown = true
        $0.markdown.denyTags = ["nav", "footer"]
    }
) {
    index(url: page.url, content: page.markdown)
}
```

### URL Filtering

Allowlist and denylist accept regular expressions. Denylist takes priority over allowlist. These run **before** a URL is enqueued, based on the URL string alone.

```swift
hermit.crawl("https://example.com") {
    $0.allowlist = ["/blog/\\d{4}/"]
    $0.denylist = ["/tag/", "\\?s="]
}
```

### Response Filters

Response filters run **after** a URL has been enqueued but **before** the full crawl GET is issued. They inspect the HTTP response (status code, headers, body) and can reject non-HTML resources, error pages, or any other response characteristic.

Each filter declares its data requirements via `requirements`, and the crawler makes the minimal request needed to satisfy all filters:

| Requirement | Request issued | When to use |
|---|---|---|
| `.url` | None | Reject by URL path, extension, or scheme |
| `.headers` | HEAD | Reject by status code or `Content-Type` |
| `.body` | GET | Reject by response body content |

Filters run in tiered phases from cheapest to most expensive. A rejection in an earlier phase skips all later phases and the crawl GET. When a `.body` filter passes, its GET response is reused for link extraction — no second request.

By default, Hermit rejects non-HTML content types and error status codes:

```swift
hermit.crawl("https://example.com") {
    // $0.filters defaults to [ContentTypeFilter(), StatusCodeFilter()]
}
```

Custom filters implement `CrawlFilter`:

```swift
struct FileExtensionFilter: CrawlFilter {
    let blockedExtensions: Set<String>

    var requirements: FilterRequirements { .url }

    func allow(_ response: HTTPClient.Response) async -> FilterDecision {
        guard let url = response.url else { return .allow }
        return blockedExtensions.contains(url.pathExtension) ? .reject : .allow
    }
}

hermit.crawl("https://example.com") {
    $0.filters = [
        FileExtensionFilter(blockedExtensions: ["pdf", "zip", "jpg"]),
        ContentTypeFilter(),
        StatusCodeFilter(),
    ]
}
```

Rejected pages appear in `CrawlResult.failed` with a `.filtered(url, filter:, context:)` error. The `FilterContext` carries the response `statusCode` and `contentType` when the rejection happened after an HTTP request (i.e. for `.headers` and `.body` filters); URL-only filters produce an empty context.

### Markdown

`denyTags` accepts any valid CSS selector — tag names, class selectors, attribute selectors, or compound selectors:

```swift
$0.markdown.denyTags = [
    "nav",
    "footer",
    ".ad-banner",
    "[role=complementary]",
]
```

## Extending

### PageProcessor

Implement `PageProcessor` to post-process every scraped page:

```swift
struct WordCounter: PageProcessor {
    func process(_ page: ScrapedPage) async throws -> ScrapedPage {
        let count = page.markdown?.split(separator: " ").count ?? 0
        print("\(page.url.path): \(count) words")
        return page
    }
}

let hermit = Hermit(processors: [WordCounter()])
```

### MarkdownConverter

Implement `MarkdownConverter` to replace the built-in HTML → Markdown logic:

```swift
struct MyConverter: MarkdownConverter {
    func convert(html: String, baseURL: URL, options: MarkdownOptions) throws -> String {
        // your implementation
    }
}

let hermit = Hermit(markdownConverter: MyConverter())
```

## CLI

The package includes `HermitCLI`, an executable target that crawls a site and mirrors it to disk as Markdown files, preserving the URL path structure:

```bash
swift run HermitCLI https://example.com --output ./site
swift run HermitCLI https://example.com --output ./site --max-depth 2 --deny-tag nav --deny-tag footer
swift run HermitCLI https://example.com --output ./site --log-level debug
```

| Option | Default | Description |
|---|---|---|
| `--output`, `-o` | `site` | Directory to write the mirrored site into |
| `--max-depth` | `3` | Maximum link depth to follow |
| `--max-pages` | unlimited | Maximum number of pages to crawl |
| `--concurrency` | `8` | Number of concurrent requests |
| `--rate-limit` | none | Maximum requests per second |
| `--deny-tag` | none | CSS selector for elements to strip before Markdown conversion. Repeatable. |
| `--include-subdomains` | false | Also crawl subdomains of the seed host |
| `--ignore-robots-txt` | false | Do not fetch or respect robots.txt |
| `--log-level` | `warning` | One of: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` |

## Running tests

```bash
swift test
```

## Authors

This library is developed by Lei Nelissen at Studio Falkland.

![Studio Falkland](./Documentation/falkland-logo-long-orange.svg)


## License

This package is open-source software licensed under EUPL. See [LICENSE.md](LICENSE.md).
