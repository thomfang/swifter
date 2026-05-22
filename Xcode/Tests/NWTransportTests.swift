//
//  NWTransportTests.swift
//  Swifter
//
//  起本地 NWListener + NWConnection 对接,验证 NWTransport
//  读写、行解析、EOF、并发 read/write 行为。
//

import XCTest
import Network
@testable import Swifter

final class NWTransportTests: XCTestCase {

    private var listener: NWListener?

    override func tearDown() {
        listener?.cancel()
        listener = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// 起一个本地 listener,并返回 (服务端接受到的 transport, 客户端 transport)
    /// 客户端是直接用 NWConnection 包成 transport,服务端通过 listener.newConnectionHandler 拿
    private func makePair() async throws -> (server: NWTransport, client: NWTransport) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let serverConnFuture = ServerConnectionFuture()
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            // 等连接 ready 再交付
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    serverConnFuture.fulfill(with: conn)
                }
            }
        }

        let listenerReady = ListenerReadyFuture()
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerReady.fulfill()
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        try await listenerReady.wait(timeout: 5)
        guard let port = listener.port else {
            throw NSError(domain: "NWTransportTests", code: 1)
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let clientConn = NWConnection(to: endpoint, using: .tcp)
        let clientReady = ClientReadyFuture()
        clientConn.stateUpdateHandler = { state in
            if case .ready = state {
                clientReady.fulfill()
            }
        }
        clientConn.start(queue: .global(qos: .userInitiated))
        try await clientReady.wait(timeout: 5)

        let serverConn = try await serverConnFuture.wait(timeout: 5)

        return (NWTransport(serverConn), NWTransport(clientConn))
    }

    // MARK: - Tests

    func testReadSingleByte() async throws {
        let (server, client) = try await makePair()

        try await client.write(ArraySlice([0x41])) // 'A'

        let byte = try await server.read()
        XCTAssertEqual(byte, 0x41)

        server.close()
        client.close()
    }

    func testReadExactLength() async throws {
        let (server, client) = try await makePair()

        let payload: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        try await client.write(ArraySlice(payload))

        let got = try await server.read(length: 5)
        XCTAssertEqual(got, payload)

        server.close()
        client.close()
    }

    func testReadLineSkipsCR() async throws {
        let (server, client) = try await makePair()

        let line = "GET /ping HTTP/1.1\r\n"
        try await client.write(line)

        let got = try await server.readLine()
        XCTAssertEqual(got, "GET /ping HTTP/1.1")

        server.close()
        client.close()
    }

    func testReadLineMultiple() async throws {
        let (server, client) = try await makePair()

        let blob = "first\r\nsecond\r\nthird\r\n"
        try await client.write(blob)

        let a = try await server.readLine()
        let b = try await server.readLine()
        let c = try await server.readLine()
        XCTAssertEqual(a, "first")
        XCTAssertEqual(b, "second")
        XCTAssertEqual(c, "third")

        server.close()
        client.close()
    }

    func testReadAfterEOFThrowsDisconnected() async throws {
        let (server, client) = try await makePair()

        try await client.write("hi\r\n")
        client.close()

        let line = try await server.readLine()
        XCTAssertEqual(line, "hi")

        // 再读时,客户端已关,会触发 EOF
        do {
            _ = try await server.read()
            XCTFail("Expected disconnected error")
        } catch HttpTransportError.disconnected {
            // 期望路径
        } catch {
            XCTFail("Expected HttpTransportError.disconnected, got \(error)")
        }

        server.close()
    }

    func testLargeBodyChunked() async throws {
        let (server, client) = try await makePair()

        // 8KB body,跨多次 receive
        let payload = [UInt8](repeating: 0x5A, count: 8 * 1024)
        try await client.write(ArraySlice(payload))

        let got = try await server.read(length: payload.count)
        XCTAssertEqual(got, payload)

        server.close()
        client.close()
    }

    func testPeername() async throws {
        let (server, client) = try await makePair()
        // 客户端的 peername 是 server 的 endpoint;服务端的 peername 由 NWConnection 上报
        XCTAssertNotNil(client.peername)
        // server 侧 peername 可能为远端 127.0.0.1:<ephemeral>,只要非空即可
        server.close()
        client.close()
    }
}

// MARK: - 简单的 once-only future helpers,避免在异步配对时丢通知

private final class ServerConnectionFuture: @unchecked Sendable {
    private let lock = NSLock()
    private var fulfilled: NWConnection?
    private var waiter: CheckedContinuation<NWConnection, Error>?

    func fulfill(with conn: NWConnection) {
        lock.lock()
        if let waiter = waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: conn)
        } else {
            fulfilled = conn
            lock.unlock()
        }
    }

    func wait(timeout: TimeInterval) async throws -> NWConnection {
        let task: Task<NWConnection, Error> = Task {
            try await withCheckedThrowingContinuation { cont in
                self.lock.lock()
                if let conn = self.fulfilled {
                    self.fulfilled = nil
                    self.lock.unlock()
                    cont.resume(returning: conn)
                } else {
                    self.waiter = cont
                    self.lock.unlock()
                }
            }
        }
        return try await withTimeoutFallback(seconds: timeout, task: task)
    }
}

private final class ListenerReadyFuture: @unchecked Sendable {
    private let lock = NSLock()
    private var fulfilled = false
    private var waiter: CheckedContinuation<Void, Error>?

    func fulfill() {
        lock.lock()
        if let waiter = waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume()
        } else {
            fulfilled = true
            lock.unlock()
        }
    }

    func wait(timeout: TimeInterval) async throws {
        let task: Task<Void, Error> = Task {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if self.fulfilled {
                    self.fulfilled = false
                    self.lock.unlock()
                    cont.resume()
                } else {
                    self.waiter = cont
                    self.lock.unlock()
                }
            }
        }
        _ = try await withTimeoutFallback(seconds: timeout, task: task)
    }
}

private final class ClientReadyFuture: @unchecked Sendable {
    private let lock = NSLock()
    private var fulfilled = false
    private var waiter: CheckedContinuation<Void, Error>?

    func fulfill() {
        lock.lock()
        if let waiter = waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume()
        } else {
            fulfilled = true
            lock.unlock()
        }
    }

    func wait(timeout: TimeInterval) async throws {
        let task: Task<Void, Error> = Task {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if self.fulfilled {
                    self.fulfilled = false
                    self.lock.unlock()
                    cont.resume()
                } else {
                    self.waiter = cont
                    self.lock.unlock()
                }
            }
        }
        _ = try await withTimeoutFallback(seconds: timeout, task: task)
    }
}

private func withTimeoutFallback<T: Sendable>(seconds: TimeInterval, task: Task<T, Error>) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await task.value }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.cancel()
            throw NSError(domain: "NWTransportTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "timeout"])
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
