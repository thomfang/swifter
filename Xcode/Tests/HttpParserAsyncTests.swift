//
//  HttpParserAsyncTests.swift
//  Swifter
//
//  HttpParser 的 async/HttpTransport 路径单元测试。
//

import XCTest
@testable import Swifter

final class HttpParserAsyncTests: XCTestCase {

    private func parse(_ raw: String) async throws -> HttpRequest {
        let parser = HttpParser()
        let transport = MockHttpTransport(raw)
        return try await parser.readHttpRequest(transport)
    }

    // MARK: - Happy path

    func testParsesSimpleGet() async throws {
        let req = try await parse("GET /ping HTTP/1.1\r\n\r\n")
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/ping")
        XCTAssertEqual(req.target, "/ping")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testParsesHeadersLowercased() async throws {
        let req = try await parse(
            "GET / HTTP/1.1\r\nHost: localhost\r\nX-Custom: yo\r\n\r\n"
        )
        XCTAssertEqual(req.headers["host"], "localhost")
        XCTAssertEqual(req.headers["x-custom"], "yo")
    }

    func testParsesQueryParams() async throws {
        let req = try await parse("GET /search?q=foo&n=2 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(req.path, "/search")
        // target 保留完整 request-target（含 query），不像 path 被拆掉。
        XCTAssertEqual(req.target, "/search?q=foo&n=2")
        let dict = Dictionary(uniqueKeysWithValues: req.queryParams)
        XCTAssertEqual(dict["q"], "foo")
        XCTAssertEqual(dict["n"], "2")
    }

    func testParsesBodyByContentLength() async throws {
        let req = try await parse(
            "POST /echo HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        )
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(String(bytes: req.body, encoding: .utf8), "hello")
    }

    func testHeaderValueWithColons() async throws {
        // Header value 含 ':' 应当被保留 (HttpParser 用 maxSplits:1)
        let req = try await parse(
            "GET / HTTP/1.1\r\nHeader1: 1:1:34\r\n\r\n"
        )
        XCTAssertEqual(req.headers["header1"], "1:1:34")
    }

    func testLargeBody() async throws {
        let bodySize = 16 * 1024
        let body = String(repeating: "x", count: bodySize)
        let req = try await parse(
            "POST / HTTP/1.1\r\nContent-Length: \(bodySize)\r\n\r\n\(body)"
        )
        XCTAssertEqual(req.body.count, bodySize)
    }

    // MARK: - Edge cases

    func testEmptyStreamThrowsDisconnected() async {
        do {
            _ = try await parse("")
            XCTFail("Expected throw")
        } catch HttpTransportError.disconnected {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedStatusLineThrowsInvalidStatusLine() async {
        do {
            _ = try await parse("GET HTTP/1.0\r\n")
            XCTFail("Expected throw")
        } catch HttpParserError.invalidStatusLine {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNegativeContentLengthThrows() async {
        do {
            _ = try await parse("GET / HTTP/1.0\r\nContent-Length: -1\r\n\r\n")
            XCTFail("Expected throw")
        } catch HttpParserError.negativeContentLength {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOversizedContentLengthThrows() async {
        // A2 回归:声明的 Content-Length 超过 maxRequestBodySize 应在读 body 前拒绝,
        // 避免 read(length:) 把 buffer 撑爆 OOM。
        do {
            let parser = HttpParser()
            parser.maxRequestBodySize = 1024
            let transport = MockHttpTransport(
                "POST / HTTP/1.1\r\nContent-Length: 2048\r\n\r\n"
            )
            _ = try await parser.readHttpRequest(transport)
            XCTFail("Expected throw")
        } catch HttpParserError.requestBodyTooLarge(let size) {
            XCTAssertEqual(size, 2048)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBodyAtLimitIsAccepted() async throws {
        // 边界:恰好等于上限应放行
        let parser = HttpParser()
        parser.maxRequestBodySize = 5
        let transport = MockHttpTransport("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello")
        let req = try await parser.readHttpRequest(transport)
        XCTAssertEqual(String(bytes: req.body, encoding: .utf8), "hello")
    }

    func testBodyShorterThanContentLengthThrows() async {
        do {
            _ = try await parse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\n")
            XCTFail("Expected throw")
        } catch HttpTransportError.disconnected {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testKeepAliveDetection() async throws {
        let req = try await parse(
            "GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n"
        )
        let parser = HttpParser()
        XCTAssertTrue(parser.supportsKeepAlive(req.headers))
    }

    func testKeepAliveAbsent() async throws {
        let req = try await parse("GET / HTTP/1.1\r\n\r\n")
        let parser = HttpParser()
        XCTAssertFalse(parser.supportsKeepAlive(req.headers))
    }
}
