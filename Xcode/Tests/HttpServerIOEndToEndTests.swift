//
//  HttpServerIOEndToEndTests.swift
//  Swifter
//
//  端到端 HTTP plain TCP 测试 —— 起一个 HttpServer,挂同步与 async handler,
//  用 URLSession 客户端请求,验证 NWListener + async handleConnection + Router enum
//  整条链路工作。
//

import XCTest
@testable import Swifter

final class HttpServerIOEndToEndTests: XCTestCase {

    func testSyncHandlerEndToEnd() async throws {
        let server = HttpServer()
        server.GET["/ping"] = { _ in .ok(.text("pong!")) }
        try await server.start(8201)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8201/ping")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as? HTTPURLResponse

        XCTAssertEqual(httpResponse?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "pong!")
    }

    func testAsyncHandlerEndToEnd() async throws {
        let server = HttpServer()
        server.setAsync("/slow") { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return .ok(.text("done"))
        }
        try await server.start(8202)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8202/slow")!
        let start = Date()
        let (data, response) = try await URLSession.shared.data(from: url)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "done")
        XCTAssertGreaterThan(elapsed, 0.08)
    }

    /// async handler 并发不应该串行 —— 5 个 100ms 请求总耗时应远小于 500ms
    func testAsyncHandlersRunConcurrently() async throws {
        let server = HttpServer()
        server.setAsync("/slow") { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return .ok(.text("done"))
        }
        try await server.start(8203)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8203/slow")!
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try await URLSession.shared.data(from: url)
                }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(start)
        // 5 个 100ms 并发应该 ~ 100-250ms 而非 500ms+
        XCTAssertLessThan(elapsed, 0.4, "Expected concurrent execution, got \(elapsed)s")
    }

    func testPostBodyEcho() async throws {
        let server = HttpServer()
        server.POST["/echo"] = { req in
            return .ok(.data(Data(req.body), contentType: "application/octet-stream"))
        }
        try await server.start(8204)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8204/echo")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("hello world".utf8)

        let (data, response) = try await URLSession.shared.upload(for: request, from: request.httpBody!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello world")
    }

    func testNotFound() async throws {
        let server = HttpServer()
        try await server.start(8205)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8205/missing")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
    }

    func testKeepAliveMultipleRequests() async throws {
        let server = HttpServer()
        let counter = AtomicInt()
        server.GET["/hit"] = { _ in
            counter.increment()
            return .ok(.text("\(counter.value)"))
        }
        try await server.start(8206)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8206/hit")!
        let session = URLSession(configuration: .default)
        // 顺序发送 3 次,URLSession 内部会复用 connection(keep-alive)
        for expectN in 1...3 {
            let (data, response) = try await session.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\(expectN)")
        }
    }
}

private final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
