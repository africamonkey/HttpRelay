# The two request forms of the proxy

**Date:** 2026-10-25
**Status:** Implemented

## Symptom

In the request details of a logged request, the URL above "REQUEST HEADERS"
was printed twice:

```
example.com:443example.com:443
```

The host and the port were there twice. The second half was the *path* of
the log entry, and for a CONNECT request the path was the whole authority.

## Root cause

A proxy sees two kinds of requests, and they have different request-targets
(RFC 9110 §7.1):

| Request | Request-target | Example |
|---|---|---|
| CONNECT | authority | `example.com:443` |
| plain HTTP | absolute form | `http://example.com:443/index.html?q=1` |

`ProxyServer.parsePathAndQuery(from:)` took the second field of the request
line and stored it as the *path* of the log entry - for both kinds of
requests. For a CONNECT request that field is the authority, so the path
became `example.com:443`. `LogEntry.fullURL` then put the authority and the
path together:

```swift
"\(host):\(port)\(path)"   // "example.com:443" + "example.com:443"
```

The log row showed the same thing: the host, and below it the authority.

The plain HTTP path had a second problem in the same function: it took the
port from `URL.port`, which is `nil` when the request target does not name
one. A browser asks for `http://example.com/index.html` - without a port -
and the proxy answered `400 Bad Request`. Every plain HTTP request to a
site on port 80 was refused.

## The fix

### A CONNECT entry has no path

The CONNECT branch of `processRequest` stores an empty path, and
`LogEntry.fullURL` only appends the path when there is one. The URL of a
CONNECT entry is the authority alone. The log row shows the port below the
host (`rowDetail`), so the information is not lost.

### `HTTPTarget` parses the absolute form

New file `HttpRelay/HTTPTarget.swift`. It parses the request target of a
plain HTTP request:

- the port may be left out; it is then the default port of the scheme
  (RFC 9110 §4.2.3). The port is checked to be one a connection can be
  made to.
- the path and the query are kept percent-encoded. `URL.path` decodes them
  (`/a%20b` becomes `/a b`), and a request that goes on the wire with a
  decoded path is not the request the client asked for.
- `hostHeaderValue` is the authority of the target, with the port only when
  it is not the default port of the scheme (RFC 9110 §7.2).
- only the `http` scheme is served. The proxy forwards plain HTTP; a client
  that wants TLS opens a tunnel with CONNECT. An `https://` target used to
  be forwarded as plain HTTP to the TLS port, which cannot work.

### The forwarded request

- The `Host` header is replaced with the authority of the target
  (RFC 9112 §3.2.2) instead of being copied from the client.
- The hop-by-hop headers are dropped (RFC 9110 §7.6.1): `Connection`,
  `Keep-Alive`, `Proxy-Authenticate`, `Proxy-Authorization`,
  `Proxy-Connection`, `TE`, `Trailer`, `Upgrade` and everything the
  `Connection` header names. `Transfer-Encoding` stays, because the body is
  passed on unchanged and its framing has to stay with it.
- The body that came with the header block is no longer lost. The request
  buffer used to stop at the end of the header block, so a body that
  arrived in the same segment as the headers was dropped - while the
  `Content-Length` header of that body was forwarded. The origin server
  then waited for bytes that never came.

## A broken tunnel and the answer to the client

A tunnel that breaks has two cases, and the client gets a different answer
in each of them:

| The tunnel | The client gets |
|---|---|
| was never up | `502 Bad Gateway` - it is waiting for a status line |
| was up | the end of the connection only |

The second case matters for a CONNECT: the client speaks TLS on the tunnel
then, and a status line in front of the TLS handshake would only corrupt
the stream. The same is true for a plain HTTP request whose target already
answered - the status line would land in the middle of the response.

`TunnelManager` keeps the state of the tunnel (`hasConnected`,
`hasReceivedResponse`, `hasFailed`) behind a lock, because the tunnel's
queue and the main queue both touch it. `answerWhenTunnelBreaks` and
`answerWhenTargetBreaks` turn that state into the answer.

A connection can also go to `.waiting` and come up anyway. The tunnel is
given up on in that state (`hasFailed`), so a later `.ready` does not bring
it up and write a second status line into the client's stream.

## The log status

`LogStore.completeEntry` used to overwrite a `failed` entry with
`completed`. A tunnel that was torn down after a failure is closed, not
completed - a failed entry stays failed.

## A port that no connection can be made to

`CONNECT example.com:70000` crashed the app: the port was turned into an
`NWEndpoint.Port` with `UInt16(port)!`, and 70000 does not fit into a
`UInt16`. Both request forms check the port now and answer `400 Bad
Request`.

## Tests

- `HttpRelayTests/HTTPTargetTests.swift` - the parsing of the request target
- `HttpRelayTests/TunnelFailureTests.swift` - the answer to a client whose
  tunnel breaks
- `HttpRelayTests/HTTPRegressionTests.swift` - the behaviour end to end:
  a CONNECT without a path in the log, a plain HTTP request without a port
  in the target, the forwarded request with its path and its `Host` header,
  the body of a request, the hop-by-hop headers, a tunnel that breaks, a
  failed tunnel in the log, and a port that no connection can be made to
