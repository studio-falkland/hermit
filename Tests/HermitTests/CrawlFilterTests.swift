import Testing
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
@testable import Hermit
import Foundation

// MARK: - Test helpers

/// Builds an `HTTPClient.Response` with the given fields for filter tests.
private func makeResponse(
    url: URL = URL(string: "https://example.com/page")!,
    status: HTTPResponseStatus = .ok,
    headers: [(String, String)] = [],
    body: String? = nil
) -> HTTPClient.Response {
    var headerBag = HTTPHeaders()
    for (name, value) in headers {
        headerBag.add(name: name, value: value)
    }
    let request = (try? HTTPClient.Request(url: url)) ?? (try! HTTPClient.Request(url: URL(string: "http://example.com")!))
    let head = HTTPResponseHead(version: .http1_1, status: status, headers: headerBag)
    let requestResponse = HTTPClient.RequestResponse(request: request, responseHead: head)
    let bodyBuffer = body.map { ByteBuffer(string: $0) }
    return HTTPClient.Response(
        host: url.host ?? "",
        status: status,
        version: .http1_1,
        headers: headerBag,
        body: bodyBuffer,
        history: [requestResponse]
    )
}

// MARK: - ContentTypeFilter

@Suite("ContentTypeFilter")
struct ContentTypeFilterTests {
    let filter = ContentTypeFilter()

    @Test func allowsHTML() async {
        let response = makeResponse(headers: [("content-type", "text/html; charset=utf-8")])
        #expect(await filter.allow(response) == .allow)
    }

    @Test func allowsXHTML() async {
        let response = makeResponse(headers: [("content-type", "application/xhtml+xml")])
        #expect(await filter.allow(response) == .allow)
    }

    @Test func rejectsPDF() async {
        let response = makeResponse(headers: [("content-type", "application/pdf")])
        #expect(await filter.allow(response) == .reject)
    }

    @Test func rejectsImage() async {
        let response = makeResponse(headers: [("content-type", "image/png")])
        #expect(await filter.allow(response) == .reject)
    }

    @Test func rejectsMissingContentType() async {
        let response = makeResponse(headers: [])
        #expect(await filter.allow(response) == .reject)
    }

    @Test func rejectsMalformedContentType() async {
        let response = makeResponse(headers: [("content-type", "")])
        #expect(await filter.allow(response) == .reject)
    }

    @Test func customAllowedTypes() async {
        let filter = ContentTypeFilter(allowedTypes: ["application/json"])
        let json = makeResponse(headers: [("content-type", "application/json")])
        let html = makeResponse(headers: [("content-type", "text/html")])
        #expect(await filter.allow(json) == .allow)
        #expect(await filter.allow(html) == .reject)
    }

    @Test func requirementsIsHeaders() {
        #expect(filter.requirements == .headers)
    }
}

// MARK: - StatusCodeFilter

@Suite("StatusCodeFilter")
struct StatusCodeFilterTests {
    let filter = StatusCodeFilter()

    @Test func allows2xx() async {
        for code in [200, 201, 204, 299] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(await filter.allow(response) == .allow, "Expected \(code) to be allowed")
        }
    }

    @Test func rejects4xx() async {
        for code in [400, 403, 404, 410, 429] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(await filter.allow(response) == .reject, "Expected \(code) to be rejected")
        }
    }

    @Test func rejects5xx() async {
        for code in [500, 502, 503, 504] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(await filter.allow(response) == .reject, "Expected \(code) to be rejected")
        }
    }

    @Test func rejects3xxByDefault() async {
        for code in [301, 302, 304, 307, 308] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(await filter.allow(response) == .reject, "Expected \(code) to be rejected by default")
        }
    }

    @Test func customAllowedCodes() async {
        let filter = StatusCodeFilter(allowedCodes: [200, 301, 302])
        #expect(await filter.allow(makeResponse(status: .ok)) == .allow)
        #expect(await filter.allow(makeResponse(status: .movedPermanently)) == .allow)
        #expect(await filter.allow(makeResponse(status: .notFound)) == .reject)
    }

    @Test func requirementsIsHeaders() {
        #expect(filter.requirements == .headers)
    }
}

// MARK: - FilterRequirements

@Suite("FilterRequirements")
struct FilterRequirementsTests {
    @Test func ordering() {
        #expect(FilterRequirements.url < .headers)
        #expect(FilterRequirements.headers < .body)
        #expect(FilterRequirements.url < .body)
    }

    @Test func maxReturnsHighest() {
        let reqs: [FilterRequirements] = [.url, .headers, .body]
        #expect(reqs.max() == .body)
    }

    @Test func maxOfUrlAndHeaders() {
        let reqs: [FilterRequirements] = [.url, .headers]
        #expect(reqs.max() == .headers)
    }

    @Test func emptyMaxIsNil() {
        let reqs: [FilterRequirements] = []
        #expect(reqs.max() == nil)
    }
}

// MARK: - Custom filter examples

@Suite("Custom CrawlFilter")
struct CustomFilterTests {
    struct FileExtensionFilter: CrawlFilter {
        let blockedExtensions: Set<String>

        var requirements: FilterRequirements { .url }

        func allow(_ response: HTTPClient.Response) async -> FilterDecision {
            guard let url = response.url else { return .allow }
            return blockedExtensions.contains(url.pathExtension) ? .reject : .allow
        }
    }

    struct BodyContainsFilter: CrawlFilter {
        let needle: String

        var requirements: FilterRequirements { .body }

        func allow(_ response: HTTPClient.Response) async -> FilterDecision {
            guard let body = response.body else { return .reject }
            return String(buffer: body).contains(needle) ? .allow : .reject
        }
    }

    @Test func urlFilterRejectsBlockedExtension() async {
        let filter = FileExtensionFilter(blockedExtensions: ["pdf", "zip"])
        let pdf = makeResponse(url: URL(string: "https://example.com/doc.pdf")!)
        let html = makeResponse(url: URL(string: "https://example.com/doc.html")!)
        #expect(await filter.allow(pdf) == .reject)
        #expect(await filter.allow(html) == .allow)
    }

    @Test func urlFilterRequirementsIsURL() {
        let filter = FileExtensionFilter(blockedExtensions: [])
        #expect(filter.requirements == .url)
    }

    @Test func bodyFilterAllowsMatchingContent() async {
        let filter = BodyContainsFilter(needle: "<article")
        let matching = makeResponse(body: "<html><body><article>Hello</article></body></html>")
        let nonMatching = makeResponse(body: "<html><body><div>Hello</div></body></html>")
        #expect(await filter.allow(matching) == .allow)
        #expect(await filter.allow(nonMatching) == .reject)
    }

    @Test func bodyFilterRejectsMissingBody() async {
        let filter = BodyContainsFilter(needle: "anything")
        let noBody = makeResponse(body: nil)
        #expect(await filter.allow(noBody) == .reject)
    }

    @Test func bodyFilterRequirementsIsBody() {
        let filter = BodyContainsFilter(needle: "")
        #expect(filter.requirements == .body)
    }
}

// MARK: - HermitError.filtered

@Suite("HermitError.filtered")
struct HermitErrorFilteredTests {
    @Test func carriesURLAndFilterName() {
        let url = URL(string: "https://example.com/blocked")!
        let error = HermitError.filtered(url, filter: "ContentTypeFilter")
        switch error {
        case .filtered(let errorURL, let filterName):
            #expect(errorURL == url)
            #expect(filterName == "ContentTypeFilter")
        default:
            Issue.record("Expected .filtered case")
        }
    }
}
