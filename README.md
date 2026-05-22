![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS-4BC51D.svg?style=flat)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-4BC51D.svg?style=flat)
![Protocols](https://img.shields.io/badge/Protocols-HTTP%201.1%20%7C%20HTTPS%20%7C%20WebSockets-4BC51D.svg?style=flat)

> **Fork notice.** This is a self-maintained fork of [httpswift/swifter](https://github.com/httpswift/swifter)
> that drops the BSD-socket I/O layer and rebuilds it on Apple's
> [Network.framework](https://developer.apple.com/documentation/network)
> (`NWListener` / `NWConnection`). The headline additions are **async
> handlers** and **HTTPS via TLSConfig**. The upstream `HttpRequest` /
> `HttpResponse` / routing / WebSocket frame parsing are preserved so
> existing handlers compile unchanged.
>
> Upstream sync (re-base or PR back) is **not** a goal; Linux is
> unsupported.

### What is Swifter?

Tiny HTTP server engine written in Swift, embeddable in apps and
extensions. Originally by [Damian Kołakowski](https://github.com/glock45)
and the swifter contributors.

### Requirements

- Swift 5.9+
- macOS 12+, iOS 15+, tvOS 15+, watchOS 8+
- No external dependencies — `Network.framework` and `Security` are
  system frameworks.

### Quick start

```swift
import Swifter

let server = HttpServer()
server["/hello"] = { req in
    .ok(.htmlBody("You asked for \(req.path)"))
}

// start() is async now
try await server.start(8080)
print("Listening on port \(try server.port())")
```

### Async handlers

```swift
let server = HttpServer()

// sync handler — unchanged API
server.GET["/sync"] = { _ in .ok(.text("hi")) }

// async handler
server.GET.setAsync("/slow") { _ in
    try await Task.sleep(nanoseconds: 100_000_000)
    return .ok(.text("done"))
}

try await server.start(8080)
```

Async handlers run concurrently per-request; five 100ms handlers complete
in ~110ms, not 500ms (see `HttpServerIOEndToEndTests.testAsyncHandlersRunConcurrently`).

### HTTPS

```swift
import Swifter

let tls = try TLSConfig.p12(
    path: "/path/to/server.p12",
    password: "your-p12-password"
)

let server = HttpServer()
server.GET["/ping"] = { _ in .ok(.text("pong over tls")) }

try await server.start(8443, tls: tls)
```

The P12 must contain a server identity (certificate + matching private
key). Minimum TLS version is pinned at 1.2 inside `TLSConfig.p12`.

Generating a self-signed P12 for development:

```sh
openssl req -x509 -newkey rsa:2048 \
    -keyout localhost.key -out localhost.crt \
    -days 3650 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

openssl pkcs12 -export -out localhost.p12 \
    -inkey localhost.key -in localhost.crt \
    -name "swifter-test" -password pass:swiftertest \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
```

### WebSockets

```swift
let server = HttpServer()

server["/echo"] = websocket(
    text:    { session, text in session.writeText(text) },
    binary:  { session, data in session.writeBinary(data) },
    connected:    { _ in print("connected") },
    disconnected: { _ in print("disconnected") }
)

try await server.start(8080)
```

WebSocketSession's `writeText` / `writeBinary` / `writeCloseFrame` are
**sync** on purpose — JS-bridge callers see the same API. Internally they
enqueue onto the transport's `sendNonBlocking` path. `session.close()`
sends a close frame and cancels the transport.

### How this fork differs from upstream

| Area                       | Upstream                              | This fork                                                        |
|----------------------------|---------------------------------------|------------------------------------------------------------------|
| Socket layer               | BSD `socket(2)` + `accept` loop       | `NWListener` + `NWConnection`                                    |
| `start()`                  | sync `try server.start(8080)`         | `try await server.start(8080, forceIPv4: false, tls: nil)`       |
| Handlers                   | `(HttpRequest) -> HttpResponse`       | sync or `(HttpRequest) async throws -> HttpResponse`             |
| `HttpResponse.switchProtocols` | `(Socket) -> Void`                | `@Sendable (HttpTransport) async -> Void`                        |
| `WebSocketSession.socket`  | `Socket`                              | `transport: HttpTransport`; added `WebSocketSession.close()`     |
| HTTPS                      | not supported                         | `TLSConfig.p12(path:password:)` → `start(_:tls:)`                |
| Linux                      | supported                             | **not** supported — Darwin-only                                  |
| iOS background suspend     | RUNNINGBOARD 0xdead10cc on socket hold | NWListener participates in system lifecycle                      |

### Migration notes for users of `master`

- Wrap `server.start(...)` in `await` and the enclosing function in
  `async throws`.
- If you used `HttpServerIODelegate.socketConnectionReceived(_:)`, rename
  to `transportConnectionReceived(_:)` and change the argument type to
  `HttpTransport`.
- `HttpResponse.switchProtocols` closure now takes `HttpTransport` and
  must be `@Sendable () async -> Void`. The built-in `websocket(...)`
  factory already does this; only matters if you call `switchProtocols`
  directly.

### Roadmap

- Keychain identity loader as an alternative to P12 files
- Optional client-certificate verification (mTLS)
- Evaluate HTTP/2 over `NWProtocolQUIC` if a use case shows up

### License

MIT, inherited from upstream. Original copyright Damian Kołakowski; fork
modifications retain the same license.
