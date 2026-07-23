import Testing
@testable import Hermit
import Foundation

@Suite("URLPattern")
struct URLPatternTests {
    @Test func matchesSimplePattern() throws {
        let pattern = try URLPattern("/blog/")
        let url = URL(string: "https://example.com/blog/post-1")!
        #expect(pattern.matches(url))
    }

    @Test func doesNotMatchUnrelatedURL() throws {
        let pattern = try URLPattern("/blog/")
        let url = URL(string: "https://example.com/about")!
        #expect(!pattern.matches(url))
    }

    @Test func stringLiteralInit() {
        let pattern: URLPattern = "/docs/"
        let url = URL(string: "https://example.com/docs/intro")!
        #expect(pattern.matches(url))
    }
}

@Suite("URLFilter")
struct URLFilterTests {
    @Test func denylistBlocksURL() throws {
        let filter = URLFilter(
            allowlist: [],
            denylist: [try URLPattern("/admin/")]
        )
        let blocked = URL(string: "https://example.com/admin/settings")!
        let allowed = URL(string: "https://example.com/about")!
        #expect(!filter.allows(blocked))
        #expect(filter.allows(allowed))
    }

    @Test func allowlistRestrictsToMatches() throws {
        let filter = URLFilter(
            allowlist: [try URLPattern("/docs/")],
            denylist: []
        )
        let allowed = URL(string: "https://example.com/docs/intro")!
        let blocked = URL(string: "https://example.com/blog/post")!
        #expect(filter.allows(allowed))
        #expect(!filter.allows(blocked))
    }

    @Test func denylistTakesPriorityOverAllowlist() throws {
        let filter = URLFilter(
            allowlist: [try URLPattern("/docs/")],
            denylist: [try URLPattern("/docs/private/")]
        )
        let blocked = URL(string: "https://example.com/docs/private/secret")!
        #expect(!filter.allows(blocked))
    }

    @Test func emptyFilterAllowsAll() {
        let filter = URLFilter(allowlist: [], denylist: [])
        let url = URL(string: "https://example.com/anything")!
        #expect(filter.allows(url))
    }
}

@Suite("DomainPolicy")
struct DomainPolicyTests {
    @Test func stayOnDomainBlocksExternal() {
        let policy = DomainPolicy(seedHost: "example.com", stayOnDomain: true, includeSubdomains: false)
        let external = URL(string: "https://other.com/page")!
        let internal_ = URL(string: "https://example.com/page")!
        #expect(!policy.allows(external))
        #expect(policy.allows(internal_))
    }

    @Test func subdomainsAllowedWhenEnabled() {
        let policy = DomainPolicy(seedHost: "example.com", stayOnDomain: true, includeSubdomains: true)
        let sub = URL(string: "https://docs.example.com/page")!
        #expect(policy.allows(sub))
    }

    @Test func subdomainsBlockedWhenDisabled() {
        let policy = DomainPolicy(seedHost: "example.com", stayOnDomain: true, includeSubdomains: false)
        let sub = URL(string: "https://docs.example.com/page")!
        #expect(!policy.allows(sub))
    }

    @Test func offDomainAllowsEverythingWhenDisabled() {
        let policy = DomainPolicy(seedHost: "example.com", stayOnDomain: false, includeSubdomains: false)
        let external = URL(string: "https://totally-different.com/page")!
        #expect(policy.allows(external))
    }
}

@Suite("URL normalization")
struct URLNormalizationTests {
    @Test func stripsFragment() {
        let url = URL(string: "https://example.com/page#section")!
        #expect(url.normalized?.absoluteString == "https://example.com/page")
    }

    @Test func stripsTrailingSlash() {
        let url = URL(string: "https://example.com/page/")!
        #expect(url.normalized?.absoluteString == "https://example.com/page")
    }

    @Test func preservesRootSlash() {
        let url = URL(string: "https://example.com/")!
        #expect(url.normalized?.absoluteString == "https://example.com/")
    }

    @Test func lowercasesHost() {
        let url = URL(string: "https://EXAMPLE.COM/page")!
        #expect(url.normalized?.host == "example.com")
    }

    @Test func stripsDefaultHTTPSPort() {
        let url = URL(string: "https://example.com:443/page")!
        #expect(url.normalized?.port == nil)
    }

    @Test func stripsDefaultHTTPPort() {
        let url = URL(string: "http://example.com:80/page")!
        #expect(url.normalized?.port == nil)
    }

    @Test func preservesNonDefaultPort() {
        let url = URL(string: "https://example.com:8080/page")!
        #expect(url.normalized?.port == 8080)
    }
}

@Suite("MarkdownConverter")
struct MarkdownConverterTests {
    let converter = DefaultMarkdownConverter()
    let base = URL(string: "https://example.com")!

    @Test func convertsHeadings() throws {
        let html = "<h1>Title</h1><h2>Subtitle</h2>"
        let md = try converter.convert(html: html, baseURL: base, options: .default)
        #expect(md.contains("# Title"))
        #expect(md.contains("## Subtitle"))
    }

    @Test func convertsParagraph() throws {
        let html = "<p>Hello world</p>"
        let md = try converter.convert(html: html, baseURL: base, options: .default)
        #expect(md.contains("Hello world"))
    }

    @Test func convertsBold() throws {
        let html = "<p><strong>bold</strong></p>"
        let md = try converter.convert(html: html, baseURL: base, options: .default)
        #expect(md.contains("**bold**"))
    }

    @Test func convertsItalic() throws {
        let html = "<p><em>italic</em></p>"
        let md = try converter.convert(html: html, baseURL: base, options: .default)
        #expect(md.contains("_italic_"))
    }

    @Test func convertsUnorderedList() throws {
        let html = "<ul><li>One</li><li>Two</li></ul>"
        let md = try converter.convert(html: html, baseURL: base, options: .default)
        #expect(md.contains("- One"))
        #expect(md.contains("- Two"))
    }

    @Test func convertsOrderedList() throws {
        let html = "<ol><li>First</li><li>Second</li></ol>"
        let md = try converter.convert(html: html, baseURL: base, options: .default)
        #expect(md.contains("1. First"))
        #expect(md.contains("2. Second"))
    }

    @Test func stripsNav() throws {
        let html = "<nav><a href='/'>Home</a></nav><p>Content</p>"
        let options = MarkdownOptions(denyTags: ["nav"])
        let md = try converter.convert(html: html, baseURL: base, options: options)
        #expect(!md.contains("Home"))
        #expect(md.contains("Content"))
    }

    @Test func stripsFooter() throws {
        let html = "<p>Content</p><footer>Copyright</footer>"
        let options = MarkdownOptions(denyTags: ["footer"])
        let md = try converter.convert(html: html, baseURL: base, options: options)
        #expect(!md.contains("Copyright"))
        #expect(md.contains("Content"))
    }
}
