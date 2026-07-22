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

// MARK: - BinaryContentFilter

@Suite("BinaryContentFilter")
struct BinaryContentFilterTests {
    let filter = BinaryContentFilter()

    @Test func allowsHTML() async throws {
        let response = makeResponse(body: "<html><body><h1>Hello</h1></body></html>")
        #expect(try await filter.allow(response) == .allow)
    }

    @Test func allowsEmptyBody() async throws {
        let response = makeResponse(body: "")
        #expect(try await filter.allow(response) == .allow)
    }

    @Test func allowsShortBody() async throws {
        // 3 bytes is below the 4-byte signature floor; we pass it through.
        let response = makeResponse(body: "abc")
        #expect(try await filter.allow(response) == .allow)
    }

    @Test func allowsMissingBody() async throws {
        let response = makeResponse(body: nil)
        #expect(try await filter.allow(response) == .allow)
    }

    @Test func rejectsPDF() async throws {
        let response = makeResponse(body: "%PDF-1.6\n%\u{fffd}\u{fffd}\u{fffd}\u{fffd}\n322 0 obj\n<<...>>")
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsPNG() async throws {
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsJPEG() async throws {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsGzip() async throws {
        let bytes: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00]
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsZIP() async throws {
        let bytes: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsWOFF() async throws {
        let bytes: [UInt8] = [0x77, 0x4F, 0x46, 0x46, 0x00, 0x01, 0x00, 0x00]
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsWOFF2() async throws {
        let bytes: [UInt8] = [0x77, 0x4F, 0x46, 0x32, 0x00, 0x01, 0x00, 0x00]
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsWebP() async throws {
        // RIFF + 4 size bytes + WEBP. The longest signature we recognise.
        var bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46]
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x57, 0x45, 0x42, 0x50])
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsRealWebP() async throws {
        // Real WebP: RIFF, then a non-zero little-endian size, then WEBP.
        // The size field is 0x00260000 = 2,539,520 — i.e. a real file size, not zero.
        var bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46]
        bytes.append(contentsOf: [0x26, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0x57, 0x45, 0x42, 0x50])
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsMP4() async throws {
        // ISO BMFF layout: 4-byte size (big-endian) + "ftyp" + major brand.
        // 0x00000018 = 24-byte box, "ftyp" at offset 4, "mp42" at offset 8.
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x18]
        bytes.append(contentsOf: [0x66, 0x74, 0x79, 0x70])
        bytes.append(contentsOf: [0x6D, 0x70, 0x34, 0x32])  // "mp42"
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsAVIF() async throws {
        // ISO BMFF with "ftyp" at offset 4 and "avif" major brand at offset 8.
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x20]
        bytes.append(contentsOf: [0x66, 0x74, 0x79, 0x70])
        bytes.append(contentsOf: [0x61, 0x76, 0x69, 0x66])  // "avif"
        let body = String(bytes: bytes, encoding: .isoLatin1) ?? ""
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsBinaryByNULByte() async throws {
        // Not a known signature, but a NUL byte in the first 512 bytes.
        let response = makeResponse(body: "garbage\u{0000}with-null-byte-in-the-middle")
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func allowsUnicodeHTML() async throws {
        // UTF-8 bytes — high-bit characters but no NUL, no binary signature.
        let body = "<html><body><p>Café 🎉</p></body></html>"
        let response = makeResponse(body: body)
        #expect(try await filter.allow(response) == .allow)
    }

    @Test func requirementsIsBody() {
        #expect(filter.requirements == .body)
    }
}

// MARK: - ContentTypeFilter

@Suite("ContentTypeFilter")
struct ContentTypeFilterTests {
    let filter = ContentTypeFilter()

    @Test func allowsHTML() async throws {
        let response = makeResponse(headers: [("content-type", "text/html; charset=utf-8")])
        #expect(try await filter.allow(response) == .allow)
    }

    @Test func allowsXHTML() async throws {
        let response = makeResponse(headers: [("content-type", "application/xhtml+xml")])
        #expect(try await filter.allow(response) == .allow)
    }

    @Test func rejectsPDF() async throws {
        let response = makeResponse(headers: [("content-type", "application/pdf")])
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsImage() async throws {
        let response = makeResponse(headers: [("content-type", "image/png")])
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsMissingContentType() async throws {
        let response = makeResponse(headers: [])
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func rejectsMalformedContentType() async throws {
        let response = makeResponse(headers: [("content-type", "")])
        #expect(try await filter.allow(response) == .reject)
    }

    @Test func customAllowedTypes() async throws {
        let filter = ContentTypeFilter(allowedTypes: ["application/json"])
        let json = makeResponse(headers: [("content-type", "application/json")])
        let html = makeResponse(headers: [("content-type", "text/html")])
        #expect(try await filter.allow(json) == .allow)
        #expect(try await filter.allow(html) == .reject)
    }

    @Test func requirementsIsHeaders() {
        #expect(filter.requirements == .headers)
    }
}

// MARK: - StatusCodeFilter

@Suite("StatusCodeFilter")
struct StatusCodeFilterTests {
    let filter = StatusCodeFilter()

    @Test func allows2xx() async throws {
        for code in [200, 201, 204, 299] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(try await filter.allow(response) == .allow, "Expected \(code) to be allowed")
        }
    }

    @Test func rejects4xx() async throws {
        for code in [400, 403, 404, 410, 429] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(try await filter.allow(response) == .reject, "Expected \(code) to be rejected")
        }
    }

    @Test func rejects5xx() async throws {
        for code in [500, 502, 503, 504] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(try await filter.allow(response) == .reject, "Expected \(code) to be rejected")
        }
    }

    @Test func rejects3xxByDefault() async throws {
        for code in [301, 302, 304, 307, 308] {
            let response = makeResponse(status: HTTPResponseStatus(statusCode: code))
            #expect(try await filter.allow(response) == .reject, "Expected \(code) to be rejected by default")
        }
    }

    @Test func customAllowedCodes() async throws {
        let filter = StatusCodeFilter(allowedCodes: [200, 301, 302])
        let result1 = try await filter.allow(makeResponse(status: .ok))
        let result2 = try await filter.allow(makeResponse(status: .movedPermanently))
        let result3 = try await filter.allow(makeResponse(status: .notFound))
        #expect(result1 == .allow)
        #expect(result2 == .allow)
        #expect(result3 == .reject)
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

        func allow(_ response: HTTPClient.Response) async throws -> FilterDecision {
            guard let url = response.url else { return .allow }
            return blockedExtensions.contains(url.pathExtension) ? .reject : .allow
        }
    }

    struct BodyContainsFilter: CrawlFilter {
        let needle: String

        var requirements: FilterRequirements { .body }

        func allow(_ response: HTTPClient.Response) async throws -> FilterDecision {
            guard let body = response.body else { return .reject }
            return String(buffer: body).contains(needle) ? .allow : .reject
        }
    }

    @Test func urlFilterRejectsBlockedExtension() async throws {
        let filter = FileExtensionFilter(blockedExtensions: ["pdf", "zip"])
        let pdf = makeResponse(url: URL(string: "https://example.com/doc.pdf")!)
        let html = makeResponse(url: URL(string: "https://example.com/doc.html")!)
        let result1 = try await filter.allow(pdf)
        let result2 = try await filter.allow(html)
        #expect(result1 == .reject)
        #expect(result2 == .allow)
    }

    @Test func urlFilterRequirementsIsURL() {
        let filter = FileExtensionFilter(blockedExtensions: [])
        #expect(filter.requirements == .url)
    }

    @Test func bodyFilterAllowsMatchingContent() async throws {
        let filter = BodyContainsFilter(needle: "<article")
        let matching = makeResponse(body: "<html><body><article>Hello</article></body></html>")
        let nonMatching = makeResponse(body: "<html><body><div>Hello</div></body></html>")
        let result1 = try await filter.allow(matching)
        let result2 = try await filter.allow(nonMatching)
        #expect(result1 == .allow)
        #expect(result2 == .reject)
    }

    @Test func bodyFilterRejectsMissingBody() async throws {
        let filter = BodyContainsFilter(needle: "anything")
        let noBody = makeResponse(body: nil)
        let result = try await filter.allow(noBody)
        #expect(result == .reject)
    }

    @Test func bodyFilterRequirementsIsBody() {
        let filter = BodyContainsFilter(needle: "")
        #expect(filter.requirements == .body)
    }
}

// MARK: - HermitError.filtered