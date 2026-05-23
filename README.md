![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20iOS%20%7C%20tvOS%20%7C%20watchOS-4BC51D.svg?style=flat)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-4BC51D.svg?style=flat)
![Protocols](https://img.shields.io/badge/Protocols-HTTP%201.1%20%7C%20HTTPS%20%7C%20WebSockets-4BC51D.svg?style=flat)

> **Fork notice.** This is a self-maintained fork of [httpswift/swifter](https://github.com/httpswift/swifter)
> that drops the BSD-socket I/O layer and rebuilds it on Apple's
> [Network.framework](https://developer.apple.com/documentation/network)
> (`NWListener` / `NWConnection`). Headline additions: **async handlers**,
> **async middleware**, **custom 404**, and **HTTPS via TLSConfig** (file
> path or in-memory bytes, with optional TLS version pinning). The upstream
> `HttpRequest` / `HttpResponse` / routing / WebSocket frame parsing are
> preserved so existing handlers compile unchanged.
>
> Upstream sync (re-base or PR back) is **not** a goal; Linux is unsupported.

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

### Async middleware

Each layer registered with `server.use { ... }` runs before route
dispatch, in registration order. Return `nil` to pass through, or an
`HttpResponse` to short-circuit. Throwing becomes a 500.

```swift
let server = HttpServer()

server.use { req in
    if req.headers["x-auth"] == nil {
        return .unauthorized(.text("missing x-auth"))
    }
    return nil   // pass through
}

server.GET["/secret"] = { _ in .ok(.text("you got it")) }

try await server.start(8080)
```

The legacy sync `server.middleware = [...]` array from upstream is still
honored and runs before the async chain.

### Custom 404

```swift
server.notFoundAsyncHandler = { req in
    .notFound(.text("no route: \(req.path)"))
}

// sync variant is still there for legacy callers
server.notFoundHandler = { _ in .notFound(.text("nope")) }
```

When both are set, the async handler wins.

### HTTPS

`TLSConfig` accepts a PKCS#12 identity from a **file path** or from
**raw bytes** (the bytes path is convenient when the P12 lives in
Keychain or another in-memory source). Minimum/maximum TLS version
default to "≥1.2 with no upper bound" but can be pinned.

```swift
import Swifter

// from a file
let tls = try TLSConfig.p12(
    path: "/path/to/server.p12",
    password: "your-p12-password"
)

// from bytes, locked to TLS 1.3 only
let bytes: Data = loadFromKeychain()
let strictTLS = try TLSConfig.p12(
    data: bytes,
    password: "your-p12-password",
    minVersion: .v1_3,
    maxVersion: .v1_3
)

let server = HttpServer()
server.GET["/ping"] = { _ in .ok(.text("pong over tls")) }
try await server.start(8443, tls: tls)
```

Only TLSv1.2 and TLSv1.3 are exposed — Apple deprecated TLSv1.0/1.1 in
macOS 12 / iOS 15.

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
| Middleware                 | sync only (`[Request -> Response?]`)  | sync chain + async chain via `server.use { ... }`                |
| Custom 404                 | `notFoundHandler` (sync)              | `notFoundHandler` (sync) + `notFoundAsyncHandler` (async)        |
| HTTPS                      | not supported                         | `TLSConfig.p12(path:...)` or `TLSConfig.p12(data:...)`, with TLS version pinning |
| `HttpResponse.switchProtocols` | `(Socket) -> Void`                | `@Sendable (HttpTransport) async -> Void`                        |
| `WebSocketSession.socket`  | `Socket`                              | `transport: HttpTransport`; added `WebSocketSession.close()`     |
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

- PEM cert + key loader as an alternative to P12 (will need temporary
  Keychain assembly on iOS, deferred until a use case shows up)
- Optional client-certificate verification (mTLS)
- Evaluate HTTP/2 over `NWProtocolQUIC` if a use case shows up

### License

MIT, inherited from upstream. Original copyright Damian Kołakowski; fork
modifications retain the same license.
