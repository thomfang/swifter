//
//  SwifterTestsWebSocketSession.swift
//  SwifterTests
//
//  Copyright © 2016 Damian Kołakowski. All rights reserved.
//

import XCTest
@testable import Swifter

class SwifterTestsWebSocketSession: XCTestCase {

    func makeSession(_ bytes: [UInt8]) -> WebSocketSession {
        return WebSocketSession(MockHttpTransport(bytes))
    }

    func testParserRejectsUnderfilledFrame() async {
        let session = makeSession([0])
        do {
            _ = try await session.readFrame()
            XCTFail("Parser should throw an error if transport has not enough data for a frame.")
        } catch {
            // expected
        }
    }

    func testParserRejectsUnmaskedFrames() async {
        let session = makeSession([0b0000_0001, 0b0000_0000, 0, 0, 0, 0])
        do {
            _ = try await session.readFrame()
            XCTFail("Parser should not accept unmasked frames.")
        } catch WebSocketSession.WsError.unMaskedFrame {
            // expected
        } catch {
            XCTFail("Expected unMaskedFrame error, got \(error)")
        }
    }

    func testParserAcceptsFinFlag() async throws {
        let session = makeSession([0b1000_0001, 0b1000_0000, 0, 0, 0, 0])
        let frame = try await session.readFrame()
        XCTAssertTrue(frame.fin)
    }

    func testParserAcceptsTextOpcode() async throws {
        let session = makeSession([0b0000_0001, 0b1000_0000, 0, 0, 0, 0])
        // 上面 fin=0 + opcode=text 是合法报文(分片头),需要继续 frame
        // 我们只读这一帧,断言 opcode
        // 注:fin=0 + text 也是允许的(fragmented start)。当 fin=0 控制帧才报错
        let frame = try await session.readFrame()
        XCTAssertEqual(frame.opcode, .text)
    }

    func testParserAcceptsBinaryOpcode() async throws {
        let session = makeSession([0b0000_0010, 0b1000_0000, 0, 0, 0, 0])
        let frame = try await session.readFrame()
        XCTAssertEqual(frame.opcode, .binary)
    }

    func testParserAcceptsCloseOpcode() async throws {
        let session = makeSession([0b1000_1000, 0b1000_0000, 0, 0, 0, 0])
        let frame = try await session.readFrame()
        XCTAssertEqual(frame.opcode, .close)
    }

    func testParserAcceptsPingOpcode() async throws {
        let session = makeSession([0b1000_1001, 0b1000_0000, 0, 0, 0, 0])
        let frame = try await session.readFrame()
        XCTAssertEqual(frame.opcode, .ping)
    }

    func testParserAcceptsPongOpcode() async throws {
        let session = makeSession([0b1000_1010, 0b1000_0000, 0, 0, 0, 0])
        let frame = try await session.readFrame()
        XCTAssertEqual(frame.opcode, .pong)
    }

    func testParserRejectsUnknownOpcodes() async {
        for opcode in [3, 4, 5, 6, 7, 11, 12, 13, 14, 15] {
            let session = makeSession([UInt8(opcode), 0b1000_0000, 0, 0, 0, 0])
            do {
                _ = try await session.readFrame()
                XCTFail("Parser should throw an error for unknown opcode: \(opcode)")
            } catch WebSocketSession.WsError.unknownOpCode {
                // expected
            } catch {
                XCTFail("Expected unknownOpCode for \(opcode), got \(error)")
            }
        }
    }

    func testParserRejectsOversizedFramePayload() async {
        // B2 回归:声明 payload 超过 maxPayloadSize 的帧应在读 payload 之前被拒,避免 OOM。
        // fin=1 + text;mask=1 + len=126(16 位扩展长度);扩展长度 = 60000(0xEA60);mask 4 字节
        let session = makeSession([0b1000_0001, 0b1111_1110, 0xEA, 0x60, 0, 0, 0, 0])
        session.maxPayloadSize = 1024
        do {
            _ = try await session.readFrame()
            XCTFail("Parser should reject frames whose payload exceeds maxPayloadSize.")
        } catch WebSocketSession.WsError.protocolError {
            // expected
        } catch {
            XCTFail("Expected protocolError, got \(error)")
        }
    }
}
