import Foundation

/// The target of a plain HTTP proxy request.
///
/// A proxy request uses the absolute form, so the target carries the
/// scheme, the host and - usually - the port. The port may be left out;
/// it is then the default port of the scheme (RFC 9110 §4.2.3).
///
/// Only the http scheme is served: the proxy forwards plain HTTP, and a
/// client that wants TLS opens a tunnel with CONNECT instead.
///
/// The path and the query are kept percent-encoded, because that is what
/// goes on the wire: `URL.path` would decode them and the request would
/// no longer be the one the client asked for.
struct HTTPTarget {
    /// The host of the target.
    let host: String
    /// The port of the target: the one of the request target, or the
    /// default port of the scheme.
    let port: Int
    /// The path of the target, percent-encoded.
    let path: String
    /// The query of the target, percent-encoded.
    let query: String?
    /// The default port of the http scheme.
    private static let defaultPort = 80

    /// Parses a request target in the absolute form.
    ///
    /// Returns `nil` when the target is not a URL with a host and the http
    /// scheme, or when its port is not a port a connection can be made to.
    init?(requestTarget: String) {
        guard let url = URL(string: requestTarget),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let port = components.port ?? Self.defaultPort
        guard (1...65535).contains(port) else {
            return nil
        }

        self.host = host
        self.port = port
        let path = components.percentEncodedPath
        self.path = path.isEmpty ? "/" : path
        self.query = components.percentEncodedQuery
    }

    /// The value of the Host header for this target: the authority of the
    /// request target, with the port only when it is not the default port
    /// of the scheme (RFC 9110 §7.2).
    var hostHeaderValue: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }
}
