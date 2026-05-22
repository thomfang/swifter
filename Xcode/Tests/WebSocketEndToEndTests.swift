//
//  WebSocketEndToEndTests.swift
//  Swifter
//
//  端到端 WebSocket 测试 —— URLSessionWebSocketTask 作为客户端,
//  swifter 起 ws echo handler,验证 text / binary / close 行为。
//

import XCTest
@testable import Swifter

final class WebSocketEndToEndTests: XCTestCase {

    func testWebSocketTextEcho() async throws {
        let server = HttpServer()
        let receivedConnected = expectation(description: "connected called")
        let receivedDisconnected = expectation(description: "disconnected called")

        server["/echo"] = websocket(
            text: { session, text in
                session.writeText(text)
            },
            connected: { _ in
                receivedConnected.fulfill()
            },
            disconnected: { _ in
                receivedDisconnected.fulfill()
            }
        )
        try await server.start(8301)
        defer { server.stop() }

        let url = URL(string: "ws://localhost:8301/echo")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        try await task.send(.string("hello"))
        let message = try await task.receive()
        switch message {
        case .string(let s):
            XCTAssertEqual(s, "hello")
        case .data:
            XCTFail("Expected string message")
        @unknown default:
            XCTFail("Unknown message type")
        }

        task.cancel(with: .normalClosure, reason: nil)
        await fulfillment(of: [receivedConnected, receivedDisconnected], timeout: 5)
    }

    func testWebSocketBinaryEcho() async throws {
        let server = HttpServer()
        server["/echo"] = websocket(
            binary: { session, data in
                session.writeBinary(data)
            }
        )
        try await server.start(8302)
        defer { server.stop() }

        let url = URL(string: "ws://localhost:8302/echo")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        let payload = Data([0x01, 0x02, 0x03, 0x04])
        try await task.send(.data(payload))
        let message = try await task.receive()
        switch message {
        case .data(let d):
            XCTAssertEqual(d, payload)
        case .string:
            XCTFail("Expected binary message")
        @unknown default:
            XCTFail("Unknown message type")
        }

        task.cancel(with: .normalClosure, reason: nil)
    }

    func testServerInitiatedClose() async throws {
        let server = HttpServer()
        let opened = expectation(description: "connection opened")
        server["/sink"] = websocket(
            text: { _, _ in },
            connected: { session in
                opened.fulfill()
                // 服务端主动关
                session.close()
            }
        )
        try await server.start(8303)
        defer { server.stop() }

        let url = URL(string: "ws://localhost:8303/sink")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        await fulfillment(of: [opened], timeout: 5)

        // 服务端 close 后客户端 receive 应该报错或返回 close
        do {
            _ = try await task.receive()
            // close 帧也可能被 URLSessionWebSocketTask 当成正常 close 不抛错;
            // 一些版本下 receive 会抛 .closeFrameReceived 或 cancellation 错;
            // 都接受
        } catch {
            // expected close path
        }

        task.cancel(with: .normalClosure, reason: nil)
    }
}
