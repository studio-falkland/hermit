import Foundation

extension URL {
    /// Returns a normalised copy of this URL, suitable for deduplication in the crawl frontier.
    ///
    /// Normalisation applies the following transformations:
    /// - Lowercases the scheme and host
    /// - Strips the fragment (e.g. `#section`)
    /// - Removes default ports (80 for HTTP, 443 for HTTPS)
    /// - Removes trailing slashes from the path, except for the root path `"/"`
    ///
    /// Returns `nil` if the URL cannot be decomposed into components.
    var normalized: URL? {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: true) else { return nil }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        // Fragments are never meaningful for crawling — two URLs that differ only by
        // fragment point to the same server resource.
        c.fragment = nil
        // Strip default ports so https://example.com:443/ and https://example.com/ are the same.
        if c.scheme == "https", c.port == 443 { c.port = nil }
        if c.scheme == "http", c.port == 80 { c.port = nil }
        // Remove a trailing slash from non-root paths so /page/ and /page compare equal.
        let path = c.path
        if path.hasSuffix("/"), path != "/" { c.path = String(path.dropLast()) }
        return c.url
    }
}
