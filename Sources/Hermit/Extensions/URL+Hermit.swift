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
        let s = absoluteString
        // Fast path: skip the URLComponents allocation when the URL is already in normal form.
        // This covers the common case of well-formed http/https URLs with lowercase scheme+host,
        // no fragment, no trailing slash, and no explicit default port.
        let hasFragment = s.contains("#")
        let hasTrailingSlash = s.count > 1 && s.last == "/"
        let hasUppercase = s.contains(where: \.isUppercase)
        let hasDefaultPort = s.hasPrefix("http:") && (s.contains(":80/") || s.hasSuffix(":80"))
                          || s.hasPrefix("https:") && (s.contains(":443/") || s.hasSuffix(":443"))
        guard hasFragment || hasTrailingSlash || hasUppercase || hasDefaultPort else { return self }
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
