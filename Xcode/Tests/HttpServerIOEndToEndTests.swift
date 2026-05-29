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

    func testNotFoundAsyncHandler() async throws {
        let server = HttpServer()
        server.notFoundAsyncHandler = { req in
            try await Task.sleep(nanoseconds: 50_000_000)
            return .notFound(.text("custom 404 for \(req.path)"))
        }
        try await server.start(8210)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8210/nowhere")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(String(data: data, encoding: .utf8), "custom 404 for /nowhere")
    }

    // MARK: - async middleware

    /// middleware 返回 nil 时放行,后续 handler 跑,响应里能看到 handler 输出。
    func testAsyncMiddlewarePassThrough() async throws {
        let server = HttpServer()
        let counter = AtomicInt()
        server.use { _ in
            counter.increment()
            return nil
        }
        server.GET["/ping"] = { _ in .ok(.text("pong")) }
        try await server.start(8211)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8211/ping")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "pong")
        XCTAssertEqual(counter.value, 1, "middleware should have run exactly once")
    }

    /// middleware 返回非 nil 时直接截胡,handler 不应再被调用。
    func testAsyncMiddlewareShortCircuit() async throws {
        let server = HttpServer()
        let handlerHits = AtomicInt()
        server.use { req in
            if req.headers["x-auth"] == nil {
                return .unauthorized(.text("missing x-auth"))
            }
            return nil
        }
        server.GET["/secret"] = { _ in
            handlerHits.increment()
            return .ok(.text("you got it"))
        }
        try await server.start(8212)
        defer { server.stop() }

        // 无 header -> 401,handler 不命中
        var unauthRequest = URLRequest(url: URL(string: "http://localhost:8212/secret")!)
        let (unauthData, unauthResp) = try await URLSession.shared.data(for: unauthRequest)
        XCTAssertEqual((unauthResp as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(String(data: unauthData, encoding: .utf8), "missing x-auth")
        XCTAssertEqual(handlerHits.value, 0)

        // 带 header -> 放行
        unauthRequest.setValue("token", forHTTPHeaderField: "x-auth")
        let (okData, okResp) = try await URLSession.shared.data(for: unauthRequest)
        XCTAssertEqual((okResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: okData, encoding: .utf8), "you got it")
        XCTAssertEqual(handlerHits.value, 1)
    }

    /// 多层 middleware 顺序执行,且 throws 会被转成 500。
    func testAsyncMiddlewareErrorBecomes500() async throws {
        let server = HttpServer()
        struct BoomError: Error {}
        server.use { _ in throw BoomError() }
        server.GET["/x"] = { _ in .ok(.text("ok")) }
        try await server.start(8213)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8213/x")!
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
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

    // MARK: - 流式写出回归(A1)

    /// A1 回归:大内存 body 必须逐块流式写出且完整、按序送达。
    /// 此前 respond 全量缓冲 + Data 二次拷贝,大 body 会 OOM(malloc 失败 trap)。
    func testLargeResponseBodyStreaming() async throws {
        let server = HttpServer()
        let size = 8 * 1024 * 1024  // 8MB,远超单块 64KB,强制走多块流式
        let payload = Data((0..<size).map { UInt8($0 & 0xFF) })
        server.GET["/big"] = { _ in .ok(.data(payload, contentType: "application/octet-stream")) }
        try await server.start(8214)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8214/big")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data.count, size)
        XCTAssertEqual(data, payload, "streamed body must be byte-for-byte complete and ordered")
    }

    /// A1 回归:大文件经 shareFile 流式下载,完整且正确(对应崩溃栈的 file 写出路径)。
    func testLargeFileStreaming() async throws {
        let size = 4 * 1024 * 1024
        let payload = Data((0..<size).map { UInt8($0 & 0xFF) })
        let tmp = NSTemporaryDirectory() + "swifter_large_\(UUID().uuidString).bin"
        try payload.write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let server = HttpServer()
        server.GET["/file"] = shareFile(tmp)
        try await server.start(8215)
        defer { server.stop() }

        let url = URL(string: "http://localhost:8215/file")!
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data.count, size)
        XCTAssertEqual(data, payload)
    }

}

private final class AtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
