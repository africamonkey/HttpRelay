# Polyglot SOCKS5 + HTTP Proxy — Design

**Date**: 2026-06-30
**Status**: Approved — pending user review of written spec

## Motivation

HttpRelay currently only handles HTTP `CONNECT`. The user's webapp at `ppov-web-api:30443` uses WebRTC with `iceTransportPolicy: "relay"`. WebRTC ICE/STUN/TURN runs over **UDP**, but Windows' direct UDP egress cannot reach the corporate TURN server (only the iOS device has access via 飞连 VPN). Result: ICE state stays at `new`, status displays literal "Connecting" indefinitely.

HTTP CONNECT proxies cannot relay UDP. The standard protocol that can is **SOCKS5** (`UDP_ASSOCIATE`).

This design adds SOCKS5 alongside the existing HTTP CONNECT, sharing TCP port `10808` so the user does not need a second port or a second proxy URL. Traffic the browser sends through HTTP CONNECT (e.g., `chrome://net-internals` style debugging, anything not via SOCKS5) keeps working; WebRTC UDP gets relayed by the new path.

## Non-goals

- TLS interception (server stays a byte tunnel)
- Authentication of any kind beyond NO-AUTH (LAN-only tool)
- Multiple iOS background-mode tricks for keeping the proxy alive (separate concern)
- HTTP→SOCKS5 protocol translation (client picks, server accepts what client sends)

## Architecture

```
   Windows/Chrome ─────► NWListener (TCP, port 10808)
                              │ newConnection
                              ▼
                       ConnectionLayer
                    (peek 1 byte, dispatch)
                            ┌─┴─────────────┐
                  byte==0x05 │               │ byte is ASCII letter
                             ▼               ▼
                    ┌─────────────┐  ┌──────────────────┐
                    │ SOCKS5Server │  │ ProxyServer.HTTPS │  ← existing
                    │   (new)      │  │   (unchanged)     │
                    └──────┬──────┘  └──────────────────┘
                           │
            ┌──────────────┼──────────────┐
            ▼              ▼              ▼
       CONNECT          BIND         UDP_ASSOCIATE
       (relay TCP)     (reject 0x07)      │
            │                            ▼
            ▼                      ┌────────────────────┐
   ┌──────────────┐                │ NWListener (UDP,    │
   │ Dst TCP conn │                │   port auto-assigned)│
   │ ←  byte  →  │                └──────────┬──────────┘
   └──────────────┘                           │
                                       (SOCKS5 UDP packet
                                        datagrams from clients)
                                              ▼
                                       ┌────────────────────┐
                                       │ SOCKS5UDPRelay     │
                                       │  parse HDR          │
                                       │  forward DATA→dst   │
                                       │  dst→reply wrap     │
                                       │  with SOCKS5 HDR    │
                                       │  →back to client    │
                                       └────────────────────┘
```

### Components

| Component | File | Lifecycle |
|-----------|------|-----------|
| `ConnectionLayer` dispatch | `ProxyServer.swift` (modify `handleNewConnection`) | reused |
| `SOCKS5Server` (TCP CONNECT, UDP_ASSOCIATE) | `SOCKS5.swift` (new) | one instance per app run |
| `SOCKS5UDPRelay` (UDP packet relay) | `SOCKS5.swift` (new) | one instance per app run; lazy-init on first UDP_ASSOCIATE |
| HTTP CONNECT path | existing `ProxyServer.swift` + `TunnelManager.swift` | unchanged |

Single shared UDP listener avoids per-association socket bookkeeping.

## Polyglot Dispatch

`ProxyServer.handleNewConnection` peeks 1 byte to discriminate:

```swift
connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] byte, _, _, _ in
    guard let first = byte?.first else { connection.cancel(); return }
    switch first {
    case 0x05:
        // SOCKS5 — hand off to SOCKS5Server with firstByte already consumed
        self?.socks5Server.handle(connection: connection)
    case 0x41...0x7A:  // uppercase ASCII letter — HTTP method (CONNECT/GET/POST/...)
        // Pushback the byte: pass to existing HTTP path via a small adapter that
        // re-reads with a 0-byte minimum and prepends the buffered byte.
        self?.handleHTTPConnection(connection, pushback: first)
    default:
        connection.cancel()
    }
}
```

**Discriminator set**:
- `0x05` (binary) — only SOCKS5 greeting version byte can match this.
- HTTP methods `CONNECT GET HEAD POST PUT DELETE OPTIONS TRACE PATCH` all start with uppercase ASCII letters (`0x41–0x5A`); we widen to lowercase too (`0x61–0x7A`) defensively. No overlap with `0x05`.

The HTTP path receives one byte too few as a result of peeking. We prepend that byte via an internal `receiveHTTPRequest` shim:

```swift
private func handleHTTPConnection(_ connection: NWConnection, pushback: UInt8) {
    var buffer: [UInt8] = [pushback]
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        if let data = data, !data.isEmpty { buffer.append(contentsOf: data) }
        // ... hand off to existing receive loop using buffer + re-schedule
    }
}
```

Internally `receiveHTTPRequest` becomes responsible for maintaining its own buffer + `lineIndex` to parse the request line and headers, since we no longer rely on receive delivering messages cleanly. We can keep the existing logic if we pre-buffer our `pushback` byte at the start of each receive callback.

**Decision**: keep existing `receiveHTTPRequest` semantics — it expects data to start at the request line. We add a one-byte peek guard before invoking it; if the byte is part of a CONNECT, push back. This is a minimal change.

## SOCKS5 Protocol

### Greeting

Client → `0x05 NMETHODS [METHODS...]`
Server → `0x05 0x00`           (NO-AUTH only — chosen method)

If the only offered method is NOT `0x00`: server replies `0x05 0xFF` and closes. Negotiation fails politely.

### Request

Client → `0x05 VER CMD RSV ATYP ADDR PORT`

| Field | Values |
|-------|--------|
| VER | `0x05` only; `0xFF` or anything else → reply `0x05 0x01 ...` and close |
| CMD | `0x01` CONNECT, `0x02` BIND, `0x03` UDP_ASSOCIATE |
| RSV | `0x00` enforced; if not, reply `0x05 0x01 ...` |
| ATYP | `0x01` IPv4, `0x03` DOMAINNAME (length-prefixed), `0x04` IPv6 |
| DOMAINNAME length | ≤ 255 octets (single byte, RFC §4); reject if declared length would overflow our read buffer |
| ADDR PORT | based on ATYP |

### Reply

Server → `0x05 STATUS RSV ATYP BND.ADDR BND.PORT`

| Status | When |
|--------|------|
| `0x00` | success |
| `0x01` | general failure (used for unsupported VER, bad RSV, DNS failure, connect failure, oversized domain) |
| `0x07` | command not supported — only used for BIND |

### CONNECT Flow

1. Parse request, extract `(host, port)`.
2. Open `NWConnection(to: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)`.
3. State-handler `.ready` → reply `0x05 0x00 0x00 0x01 0x00 0x00 0x00 0x00 0x00 0x00` (BND 0.0.0.0:0), then begin bidir forward.
4. State-handler `.failed` / `.cancelled` → reply `0x05 0x01 0x00 0x01 ...`, close client.
5. Bidirectional forward loop:
   - `client.receive(...) → server.send(content: data, isComplete: isComplete, ...)`
   - `server.receive(...) → client.send(content: data, isComplete: isComplete, ...)`
   - Either side error or `isComplete == true` → cancel the other side.
6. `isComplete: true` carries through `send` so the final payload + FIN arrive atomically (same fix already proven for HTTP CONNECT — see AGENTS.md "Common Issues Fixed" #2 and #5).

### UDP_ASSOCIATE Flow

1. Parse request; the `host`/`port` fields in the request are the client's own preferred UDP relay address (typically `0.0.0.0:0` meaning "server picks"). **We ignore them.** What the server replies with is the address of the server's UDP listener (allocated by `NWListener(using: .udp, on: .any)` at first UDP_ASSOCIATE).

2. Make sure `SOCKS5UDPRelay.start()` has been called. Idempotent — first call creates listener, subsequent calls just return the bound port.

3. Reply `0x05 0x00 0x00 0x01` + 4 byte BND.IP4 + 2 byte BND.PORT = the UDP listener's `port` and a 0.0.0.0 addr (responder's interface isn't required to be reachable; client sends datagrams here).

4. Now the client will start sending **SOCKS5 UDP datagrams** to `BND.PORT`. These arrive on the UDP listener. We do not close the TCP control connection — Chrome keeps the TCP open as long as the association is alive and closes it when done.

### Bidirectional Forwarding (TCP)

Inline in SOCKS5Server. Recursive structure identical in spirit to `TunnelManager.forwardToClient`, but written fresh:

- Use `receive(minimumIncompleteLength: 1, ...)` server side, `0` client side.
- Track byte counts (with `Task { @MainActor in self.logStore.add... }` mirroring the existing pattern; for now we don't need per-tunnel entry since we don't have a LogEntry for SOCKS5 — extend later if useful).

## SOCKS5 UDP Relay

### Packet Format (RFC 1928 §4)

```
+----+----+----+----+----+----+----+----+----+----+----+...+----+
|RSV |FRAG|ATYP| DST.ADDR       | DST.PORT       | DATA      |
+----+----+----+----+----+----+----+----+----+----+----+...+----+
  2   1    1     variable        2                variable
```

- RSV = 2 zero bytes
- FRAG = 1 byte; we accept `0x00` only (RFC 1928 §6: fragmentation not implemented)
- ATYP = 1/3/4 for IPv4/DOMAIN/IPv6

### Data Flow

```
browser ──UDP datagram (SOCKS5 HDR + DATA)──► server UDP listener

server's NWListener(UDP) hands each remote peer a NWConnection:
  → receiveMessage loop:
     parse SOCKS5 HDR → DST
     record: dstToClient[dst_endpoint] = client_udp_endpoint  (= nc.remoteEndpoint)
     open or reuse an outbound UDP NWConnection to DST
     send DATA over it

real DST ──UDP reply──► server UDP listener

another NWConnection inbound (remote = real DST endpoint):
  → receiveMessage loop:
     reverse-lookup dstToClient[real_dst_endpoint] = client_udp_endpoint
     build SOCKS5 reply packet (RSV=00 00 FRAG=00 ATYP=01 DST.ADDR=<dst-ipv4> DST.PORT=<dst-port> + DATA)
     send on a fresh NWConnection to client_udp_endpoint
```

### Critical Pitfalls

1. **Reply association** — many real-time protocols (TURN-over-UDP, STUN) respond from a *different port* than the request went to (NAT rebinding). Our key for reverse lookup is `(DST_addr, DST_port)` — accept either matching `(real_dst_addr, real_dst_port)` since these typically match.
2. **Same client UDP port, multiple DSTs** — common with WebRTC (TURN allocations, peer reflexive candidates). Always key by `(client_udp_endpoint, dst_endpoint)` pair. We do this implicitly because the SOCKS5 HDR carries DST per datagram.
3. **`receiveMessage` loop** — UDP via NWConnection is fire-and-receive per datagram. Always reschedule `nc.receiveMessage` inside the callback.
4. **Outbound UDP NWConnection pooling** — keyed by `dst_endpoint`, not by datagram. Reuse across many SOCKS5 datagrams to the same DST.

### Lifecycle

- One `NWListener(using: .udp, on: .any)` per process.
- Created lazily on the first UDP_ASSOCIATE.
- Stays alive for the lifetime of the proxy app session.
- **Not** shut down when a client disconnects — keeps things simple. A future iteration can mark `dstToClient` entries' owning client-UDP-connection as gone and garbage-collect entries whose client has left.

## File Structure

- **Add**: `HttpRelay/SOCKS5.swift`
  - `SOCKS5Server` — public class, single instance per `ProxyServer`. Owns TCP handlers and a lazily-created `SOCKS5UDPRelay`.
  - `SOCKS5UDPRelay` — internal class. Owns the UDP listener, the mapping dictionary, the send/receive loops.
  - Constants: `kSOCKS5Version = 0x05`, reply status bytes, ATYP values, header sizes.
  - Helpers: `parseRequest(_:)`, `buildReply(status:addr:port:)`.

- **Modify**: `HttpRelay/ProxyServer.swift`
  - `handleNewConnection` reads 1 byte and dispatches.
  - New helper: `handleHTTPConnection(_:pushback:)` for the HTTP-side byte pushback.
  - Hold reference to `SOCKS5Server` instance.

- **Unchanged**: `TunnelManager.swift`.

## Error Handling Summary

| Situation | Server Action |
|-----------|---------------|
| First byte not `0x05` and not uppercase ASCII | Close |
| SOCKS5 greeting without `0x00` NO-AUTH | Reply `0x05 0xFF`, close |
| Request VER != `0x05`, RSV != `0x00`, ATYP invalid, or domain length > 255 | Reply `0x05 0x01 0x00 0x01 ...`, close |
| BIND request | Reply `0x05 0x07 0x00 0x01 ...`, close |
| CONNECT to unreachable target | NWConnection reaches `.failed`, server replies `0x05 0x01 ...` |
| UDP datagram with bad header | Silently drop (UDP semantics) |
| UDP datagram with FRAG != `0x00` | Drop (no fragmentation support per RFC 1928 §6) |
| Reply arrives at server for an unknown DST | Silently drop, do not send SOCKS5 reply |
| Browser closes TCP control connection | Leave UDP listener alive; clear that client's mappings lazily |
| iOS app shutdown | Cancel UDP listener, clean up TCP state through ProxyServer.stop() |

UDP errors are silent because `NWConnection` UDP semantics are fire-and-forget at the socket level.

## Testing

`HttpRelayTests/HttpRelayTests.swift` is currently empty. We seed it with:

| Test | Description | Verifies |
|------|-------------|---------|
| `test_socks5_greeting_no_auth` | Send `0x05 0x01 0x00` | Server replies `0x05 0x00` |
| `test_socks5_greeting_no_acceptable_method` | Send `0x05 0x01 0x02` | Server replies `0x05 0xFF`, closes |
| `test_socks5_connect_to_local_echo` | Run a local NWListener (echo TCP), SOCKS5 CONNECT to it, send a 64-byte payload | Echo server got 64 bytes, client got 64 bytes |
| `test_socks5_connect_failure` | CONNECT to `127.0.0.1:1` (closed) | Reply is non-zero status, client closes |
| `test_socks5_bind_rejected` | Send `0x05 0x02 ...` | Reply status `0x07` |
| `test_socks5_udp_associate_relay` | Run two local UDP services (a, b), SOCKS5 UDP_ASSOCIATE, send a datagram through SOCKS5 with DST=b | b receives the payload |
| `test_socks5_udp_reply_routing` | Continue from above: b sends reply, server wraps it with SOCKS5 HDR and sends back | a (client side) receives the reply correctly |
| `test_polyglot_dispatch_socks5` | Real NWConnection sending `0x05 ...` | Routed to SOCKS5Server |
| `test_polyglot_dispatch_http` | Real NWConnection sending `CONNECT ...` | Routed to HTTP path |

All tests run with `NWListener` + `NWConnection` in-process; no external test server dependency.

## Rollout & Verification

After implementation:

1. Build & run on device.
2. Switch Chrome proxy from `http://192.168.2.162:10808` to `socks5://192.168.2.162:10808` (a.k.a. same port, different protocol field in settings).
3. Visit the user's `ppov-web` page.
4. Verify heartbeat works as before (HTTP signaling via SOCKS5 TCP CONNECT).
5. Verify the "Connecting" status transitions away (SOCKS5 UDP relay goes through for WebRTC ICE/STUN/TURN).
6. Watch the iOS console for `[SOCKS5]` logs to confirm:
   - Greeting completes with NO-AUTH
   - CONNECT for ppov-web-api sees UDP datagrams flowing through `[SOCKS5UDPRelay]`
7. Capture a fresh log to `/tmp/log.txt` for the user to verify, mirroring how previous fixes were validated.

## Out of Scope / Future Work

- Authentication (USERNAME/PASSWORD) — never required for this LAN tool; would need to add credential storage UI on iOS.
- Fragmentation support (SOCKS5 FRAG != 0) — RFC allows ignoring; modern clients set 0.
- Configurable UDP listener port (currently `.any`).
- Per-tunnel byte counters / log entries for SOCKS5 connections — same LogStore model as HTTP CONNECT, deferred.
- Multiple UDP listeners if `.any` is contended (rare; revisit if seen in profiling).
