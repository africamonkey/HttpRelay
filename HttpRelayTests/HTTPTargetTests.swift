import Testing
import Foundation
@testable import HttpRelay

@Suite("HTTP proxy target")
struct HTTPTargetTests {

    /// The port may be left out of the request target; it is then the
    /// default port of the scheme.
    @Test func a_target_without_a_port_uses_the_default_port_of_the_scheme() throws {
        let target = try #require(HTTPTarget(requestTarget: "http://example.com/index.html"))
        #expect(target.host == "example.com")
        #expect(target.port == 80)
        #expect(target.path == "/index.html")
        #expect(target.query == nil)
    }

    /// Only plain HTTP is served: the proxy forwards plain HTTP, and a
    /// client that wants TLS opens a tunnel with CONNECT.
    @Test func a_target_with_another_scheme_is_rejected() {
        #expect(HTTPTarget(requestTarget: "https://example.com/") == nil)
        #expect(HTTPTarget(requestTarget: "ftp://example.com/") == nil)
        #expect(HTTPTarget(requestTarget: "//example.com/index.html") == nil)
    }

    @Test func a_target_with_a_port_keeps_it() throws {
        let target = try #require(HTTPTarget(requestTarget: "http://example.com:8080/index.html"))
        #expect(target.port == 8080)
        #expect(target.path == "/index.html")
    }

    /// The Host header carries the port only when it is not the default
    /// port of the scheme (RFC 9110 §7.2).
    @Test func the_host_header_carries_the_port_only_when_it_is_not_the_default() throws {
        let withPort = try #require(HTTPTarget(requestTarget: "http://example.com:8080/"))
        #expect(withPort.hostHeaderValue == "example.com:8080")

        let withoutPort = try #require(HTTPTarget(requestTarget: "http://example.com/"))
        #expect(withoutPort.hostHeaderValue == "example.com")

        let defaultPort = try #require(HTTPTarget(requestTarget: "http://example.com:80/"))
        #expect(defaultPort.hostHeaderValue == "example.com")
    }

    /// The path goes on the wire percent-encoded, so it has to stay that
    /// way when the request is forwarded.
    @Test func the_path_and_the_query_of_a_target_stay_percent_encoded() throws {
        let target = try #require(HTTPTarget(requestTarget: "http://example.com/a%20b?q=x%20y"))
        #expect(target.path == "/a%20b")
        #expect(target.query == "q=x%20y")
    }

    @Test func a_target_without_a_path_gets_the_root_path() throws {
        let target = try #require(HTTPTarget(requestTarget: "http://example.com"))
        #expect(target.path == "/")
    }

    /// A target that is not a URL with a host cannot be proxied.
    @Test func a_target_that_is_not_absolute_is_rejected() {
        #expect(HTTPTarget(requestTarget: "/index.html") == nil)
        #expect(HTTPTarget(requestTarget: "*") == nil)
    }

    /// A port no connection can be made to is rejected instead of
    /// crashing the proxy.
    @Test func a_target_with_an_impossible_port_is_rejected() {
        #expect(HTTPTarget(requestTarget: "http://example.com:70000/") == nil)
        #expect(HTTPTarget(requestTarget: "http://example.com:0/") == nil)
    }
}
