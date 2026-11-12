import Foundation
import LyricsKit

/// Sends every service request over HTTPS.
///
/// LyricsKit calls NetEase and Kugou over plain HTTP, which macOS refuses in a
/// packaged app. Command-line tools are exempt, so this only shows up in the app.
public struct SecureHTTPClient: HTTPClient {
    /// This host's certificate does not match its name. The replacement serves
    /// the same API with a valid one.
    private static let replacementHosts = ["mobilecdn.kugou.com": "mobileservice.kugou.com"]

    private let base: HTTPClient

    public init(base: HTTPClient = URLSessionHTTPClient.shared) {
        self.base = base
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await base.data(for: Self.secured(request))
    }

    static func secured(_ request: URLRequest) -> URLRequest {
        guard let url = request.url,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return request }
        parts.scheme = "https"
        if let host = parts.host, let replacement = replacementHosts[host] {
            parts.host = replacement
        }
        var secured = request
        secured.url = parts.url ?? url
        return secured
    }
}
