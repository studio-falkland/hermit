# Hermit — Agent Briefing

## What This Is

Hermit is a pure Swift web crawling and scraping library for server-side use.
It has no browser, no LLM integration, and no UI layer. It fetches HTML over
HTTP and turns it into structured data or Markdown.

## Stack

| Concern | Package |
|---|---|
| HTTP | `async-http-client` (SwiftNIO-backed) |
| HTML parsing | `SwiftSoup` |
| Frontier queue | `swift-collections` (`Deque`) |
| Concurrency | Swift structured concurrency — `TaskGroup`, `actor`, `AsyncThrowingStream` |

Minimum platform: **macOS 14 / Swift 5.9**.

## Module Map

```
Sources/Hermit/
├── Core/               # Hermit.swift, Crawler.swift, Scraper.swift, CrawlFrontier.swift
├── Configuration/      # CrawlConfiguration, ScrapeConfiguration, NetworkConfiguration,
│                       # MarkdownOptions, HermitConfiguration
├── Models/             # CrawledPage, ScrapedPage, CrawlResult, PageMetadata, HermitError
├── Networking/         # HermitHTTPClient, RateLimiter
├── Filtering/          # URLPattern, URLFilter, DomainPolicy
├── Parsing/            # HTMLParser, MarkdownConverter + default implementation
├── Processing/         # PageProcessor protocol
└── Extensions/         # URL+Hermit
```

## Key Invariants

- **`CrawlFrontier` is an `actor`.** All access to the visited set and queue must
  go through it. Never add URL deduplication logic anywhere else.
- **URLs are normalized before entering the visited set.** Normalization happens
  in `HTMLParser.extractLinks` via `URL.normalized`. Fragments are stripped,
  scheme and host are lowercased, default ports are removed, trailing slashes
  (except root `/`) are removed.
- **A URL is inserted into `visited` at enqueue time**, not at fetch time. This
  means every URL in the queue, in-flight, or already fetched is in `visited`.
  The guard `!visited.contains(link)` is the single deduplication gate.
- **`HermitHTTPClient` is a struct wrapping `AsyncHTTPClient.HTTPClient`.**
  The underlying client is owned by `Hermit` and shared across all operations.
  Never create an `HTTPClient` outside of `Hermit.init`.
- **`RateLimiter` uses `Task.sleep`, never `Thread.sleep`.** Do not block NIO
  event loop threads.
- **`ScrapedPage` is `@unchecked Sendable`** because `SwiftSoup.Document` is a
  class without `Sendable` conformance. The document is treated as read-only
  after construction; do not mutate it.

## Coding Conventions

- No alignment spaces. Each line is formatted independently.
  ```swift
  // Wrong
  var foo: Int     = 1
  var longer: Bool = true

  // Right
  var foo: Int = 1
  var longer: Bool = true
  ```
- `public` on anything in the public API. Internal types have no access modifier.
- All public configuration types are `struct` with a `static let default` property.
- Use closure-based configuration: `configure: (inout Config) -> Void = { _ in }`.
- `actor` for any shared mutable state. No `DispatchQueue`, no `NSLock`.
- `AsyncThrowingStream` for all streaming APIs. Never `AsyncStream` (errors must
  propagate).
- Errors are always `HermitError` at the boundary. Wrap underlying errors using
  `.network(url, underlying:)` or `.parsing(url, underlying:)`.
- No force-unwraps except in `ExpressibleByStringLiteral` inits where an invalid
  literal is a programming error.
- `try?` is acceptable in HTML parsing helpers where a missing element is
  non-fatal. Never use `try?` when wrapping network calls.
