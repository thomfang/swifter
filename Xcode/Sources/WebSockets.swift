//
//  HttpHandlers+WebSockets.swift
//  Swifter
//
//  Copyright © 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation

@available(*, deprecated, message: "Use websocket(text:binary:pong:connected:disconnected:) instead.")
public func websocket(_ text: @escaping @Sendable (WebSocketSession, String) -> Void,
                      _ binary: @escaping @Sendable (WebSocketSession, [UInt8]) -> Void,
                      _ pong: @escaping @Sendable (WebSocketSession, [UInt8]) -> Void) -> (@Sendable (HttpRequest) -> HttpResponse) {
    return websocket(text: text, binary: binary, pong: pong)
}

// swiftlint:disable function_body_length
public func websocket(
    text: (@Sendable (WebSocketSession, String) -> Void)? = nil,
    binary: (@Sendable (WebSocketSession, [UInt8]) -> Void)? = nil,
    pong: (@Sendable (WebSocketSession, [UInt8]) -> Void)? = nil,
    connected: (@Sendable (WebSocketSession) -> Void)? = nil,
    disconnected: (@Sendable (WebSocketSession) -> Void)? = nil,
    // 延迟读取:在建连(创建 session)时求值,使 server 级配置对之后的连接生效,与注册顺序无关
    maxPayloadSize: @escaping @Sendable () -> Int = { 16 * 1024 * 1024 }
) -> (@Sendable (HttpRequest) -> HttpResponse) {
    return { request in
        guard request.hasTokenForHeader("upgrade", token: "websocket") else {
            return .badRequest(.text("Invalid value of 'Upgrade' header: \(request.headers["upgrade"] ?? "unknown")"))
        }
        guard request.hasTokenForHeader("connection", token: "upgrade") else {
            return .badRequest(.text("Invalid value of 'Connection' header: \(request.headers["connection"] ?? "unknown")"))
        }
        guard let secWebSocketKey = request.headers["sec-websocket-key"] else {
            return .badRequest(.text("Invalid value of 'Sec-Websocket-Key' header: \(request.headers["sec-websocket-key"] ?? "unknown")"))
        }
        let protocolSessionClosure: @Sendable (HttpTransport) async -> Void = { transport in
            let session = WebSocketSession(transport)
            session.maxPayloadSize = maxPayloadSize()
            // 分片状态(payload / fragmentedOpCode)是连接内单线程消费 —— readLoop 串行处理
            // 收到的每个 frame,因此用 class 包装规避 capture-by-var 在并发上下文中的告警
            let state = FragmentState()

            connected?(session)

            do {
                try await WSReadLoop.readLoop(
                    session: session,
                    transport: transport,
                    state: state,
                    text: text,
                    binary: binary,
                    pong: pong
                )
            } catch let error {
                switch error {
                case WebSocketSession.Control.close:
                    break
                case HttpTransportError.disconnected:
                    // 客户端正常断开 —— 读 EOF 在 NWConnection 上表现为 disconnected,
                    // 跟主动 close 等价,不需要打印
                    break
                case WebSocketSession.WsError.unknownOpCode:
                    print("Unknown Op Code: \(error)")
                case WebSocketSession.WsError.unMaskedFrame:
                    print("Unmasked frame: \(error)")
                case WebSocketSession.WsError.invalidUTF8:
                    print("Invalid UTF8 character: \(error)")
                case WebSocketSession.WsError.protocolError:
                    print("Protocol error: \(error)")
                default:
                    print("Unkown error \(error)")
                }
                session.writeCloseFrame()
            }

            disconnected?(session)
        }
        let secWebSocketAccept = String.toBase64((secWebSocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").sha1())
        let headers = ["Upgrade": "WebSocket", "Connection": "Upgrade", "Sec-WebSocket-Accept": secWebSocketAccept]
        return HttpResponse.switchProtocols(headers, protocolSessionClosure)
    }
}

/// 私有命名空间,把 readLoop 抽出来避免 @Sendable 闭包内捕获可变 var
private enum WSReadLoop {}

private final class FragmentState: @unchecked Sendable {
    var opcode: WebSocketSession.OpCode = .close
    var payload: [UInt8] = []
}

private extension WSReadLoop {
    static func readLoop(
        session: WebSocketSession,
        transport: HttpTransport,
        state: FragmentState,
        text: (@Sendable (WebSocketSession, String) -> Void)?,
        binary: (@Sendable (WebSocketSession, [UInt8]) -> Void)?,
        pong: (@Sendable (WebSocketSession, [UInt8]) -> Void)?
    ) async throws {
        while true {
            let frame = try await session.readFrame()
            try handleOperationCode(
                frame: frame,
                session: session,
                transport: transport,
                state: state,
                text: text,
                binary: binary,
                pong: pong
            )
        }
    }

    static func handleOperationCode(
        frame: WebSocketSession.Frame,
        session: WebSocketSession,
        transport: HttpTransport,
        state: FragmentState,
        text: (@Sendable (WebSocketSession, String) -> Void)?,
        binary: (@Sendable (WebSocketSession, [UInt8]) -> Void)?,
        pong: (@Sendable (WebSocketSession, [UInt8]) -> Void)?
    ) throws {
        switch frame.opcode {
        case .continue:
            if state.opcode == .close {
                transport.close()
            }
            frame.opcode = state.opcode
            if frame.fin {
                state.payload.append(contentsOf: frame.payload)
                guard state.payload.count <= session.maxPayloadSize else {
                    throw WebSocketSession.WsError.protocolError("Fragmented message exceeds the maximum allowed size.")
                }
                frame.payload = state.payload
                state.payload = []
                state.opcode = .close
            }
            try handleOperationCode(
                frame: frame, session: session, transport: transport,
                state: state, text: text, binary: binary, pong: pong
            )
        case .text:
            if let handleText = text {
                if frame.fin {
                    if !state.payload.isEmpty {
                        throw WebSocketSession.WsError.protocolError("Continuing fragmented frame cannot have an operation code.")
                    }
                    var textFramePayload = frame.payload.map { Int8(bitPattern: $0) }
                    textFramePayload.append(0)
                    if let text = String(validatingUTF8: textFramePayload) {
                        handleText(session, text)
                    } else {
                        throw WebSocketSession.WsError.invalidUTF8("")
                    }
                } else {
                    state.payload.append(contentsOf: frame.payload)
                    guard state.payload.count <= session.maxPayloadSize else {
                        throw WebSocketSession.WsError.protocolError("Fragmented message exceeds the maximum allowed size.")
                    }
                    state.opcode = .text
                }
            }
        case .binary:
            if let handleBinary = binary {
                if frame.fin {
                    if !state.payload.isEmpty {
                        throw WebSocketSession.WsError.protocolError("Continuing fragmented frame cannot have an operation code.")
                    }
                    handleBinary(session, frame.payload)
                } else {
                    state.payload.append(contentsOf: frame.payload)
                    guard state.payload.count <= session.maxPayloadSize else {
                        throw WebSocketSession.WsError.protocolError("Fragmented message exceeds the maximum allowed size.")
                    }
                    state.opcode = .binary
                }
            }
        case .close:
            throw WebSocketSession.Control.close
        case .ping:
            if frame.payload.count > 125 {
                throw WebSocketSession.WsError.protocolError("Payload gretter than 125 octets.")
            } else {
                session.writeFrame(ArraySlice(frame.payload), .pong)
            }
        case .pong:
            if let handlePong = pong {
                handlePong(session, frame.payload)
            }
        }
    }
}

public final class WebSocketSession: @unchecked Sendable, Hashable, Equatable {

    public enum WsError: Error { case unknownOpCode(String), unMaskedFrame(String), protocolError(String), invalidUTF8(String) }
    public enum OpCode: UInt8 { case `continue` = 0x00, close = 0x08, ping = 0x09, pong = 0x0A, text = 0x01, binary = 0x02 }
    public enum Control: Error { case close }

    public final class Frame {
        public var opcode = OpCode.close
        public var fin = false
        public var rsv1: UInt8 = 0
        public var rsv2: UInt8 = 0
        public var rsv3: UInt8 = 0
        public var payload = [UInt8]()
    }

    public let transport: HttpTransport
    /// 保证 writeFrame 三段字节(opcode、长度、payload)原子 enqueue
    private let writeLock = NSLock()

    /// 单帧 payload / 分片消息累积总量上限(字节)。防御 client 声明超大帧长
    /// 或海量分片把 read buffer 撑爆 OOM。默认 16MB,可按需调整。
    public var maxPayloadSize: Int = 16 * 1024 * 1024

    public init(_ transport: HttpTransport) {
        self.transport = transport
    }

    deinit {
        // deinit 不能 await;只 cancel underlying transport,close frame 由调用方
        // 主动 close() 时发送
        transport.close()
    }

    public func writeText(_ text: String) {
        self.writeFrame(ArraySlice(text.utf8), OpCode.text)
    }

    public func writeBinary(_ binary: [UInt8]) {
        self.writeBinary(ArraySlice(binary))
    }

    public func writeBinary(_ binary: ArraySlice<UInt8>) {
        self.writeFrame(binary, OpCode.binary)
    }

    public func writeFrame(_ data: ArraySlice<UInt8>, _ op: OpCode, _ fin: Bool = true) {
        let finAndOpCode = UInt8(fin ? 0x80 : 0x00) | op.rawValue
        let maskAndLngth = encodeLengthAndMaskFlag(UInt64(data.count), false)
        writeLock.lock()
        defer { writeLock.unlock() }
        transport.sendNonBlocking(ArraySlice([finAndOpCode]))
        transport.sendNonBlocking(ArraySlice(maskAndLngth))
        transport.sendNonBlocking(data)
    }

    public func writeCloseFrame() {
        writeFrame(ArraySlice("".utf8), .close)
    }

    /// 主动关闭 —— 发 close frame 并 cancel underlying transport(幂等)。
    public func close() {
        writeCloseFrame()
        transport.close()
    }

    private func encodeLengthAndMaskFlag(_ len: UInt64, _ masked: Bool) -> [UInt8] {
        let encodedLngth = UInt8(masked ? 0x80 : 0x00)
        var encodedBytes = [UInt8]()
        switch len {
        case 0...125:
            encodedBytes.append(encodedLngth | UInt8(len))
        case 126...UInt64(UINT16_MAX):
            encodedBytes.append(encodedLngth | 0x7E)
            encodedBytes.append(UInt8(len >> 8 & 0xFF))
            encodedBytes.append(UInt8(len >> 0 & 0xFF))
        default:
            encodedBytes.append(encodedLngth | 0x7F)
            encodedBytes.append(UInt8(len >> 56 & 0xFF))
            encodedBytes.append(UInt8(len >> 48 & 0xFF))
            encodedBytes.append(UInt8(len >> 40 & 0xFF))
            encodedBytes.append(UInt8(len >> 32 & 0xFF))
            encodedBytes.append(UInt8(len >> 24 & 0xFF))
            encodedBytes.append(UInt8(len >> 16 & 0xFF))
            encodedBytes.append(UInt8(len >> 08 & 0xFF))
            encodedBytes.append(UInt8(len >> 00 & 0xFF))
        }
        return encodedBytes
    }

    // swiftlint:disable function_body_length
    public func readFrame() async throws -> Frame {
        let frm = Frame()
        let fst = try await transport.read()
        frm.fin = fst & 0x80 != 0
        frm.rsv1 = fst & 0x40
        frm.rsv2 = fst & 0x20
        frm.rsv3 = fst & 0x10
        guard frm.rsv1 == 0 && frm.rsv2 == 0 && frm.rsv3 == 0
            else {
            throw WsError.protocolError("Reserved frame bit has not been negociated.")
        }
        let opc = fst & 0x0F
        guard let opcode = OpCode(rawValue: opc) else {
            throw WsError.unknownOpCode("\(opc)")
        }
        if frm.fin == false {
            switch opcode {
            case .ping, .pong, .close:
                throw WsError.protocolError("Control frames must not be fragmented.")
            default:
                break
            }
        }
        frm.opcode = opcode
        let sec = try await transport.read()
        let msk = sec & 0x80 != 0
        guard msk else {
            throw WsError.unMaskedFrame("A client must mask all frames that it sends to the server.")
        }
        var len = UInt64(sec & 0x7F)
        if len == 0x7E {
            let b0 = UInt64(try await transport.read()) << 8
            let b1 = UInt64(try await transport.read())
            len = UInt64(littleEndian: b0 | b1)
        } else if len == 0x7F {
            let b0 = UInt64(try await transport.read()) << 56
            let b1 = UInt64(try await transport.read()) << 48
            let b2 = UInt64(try await transport.read()) << 40
            let b3 = UInt64(try await transport.read()) << 32
            let b4 = UInt64(try await transport.read()) << 24
            let b5 = UInt64(try await transport.read()) << 16
            let b6 = UInt64(try await transport.read()) << 8
            let b7 = UInt64(try await transport.read())
            len = UInt64(littleEndian: b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7)
        }

        let m0 = try await transport.read()
        let m1 = try await transport.read()
        let m2 = try await transport.read()
        let m3 = try await transport.read()
        let mask = [m0, m1, m2, m3]
        // 用 UInt64 比较避免 Int(len) 在超大 len 上溢出崩溃,同时拦截恶意超大帧。
        // max(0,) 防御:maxPayloadSize 是 public var,用户若误设负值,UInt64(负) 会崩。
        guard len <= UInt64(max(0, maxPayloadSize)) else {
            throw WsError.protocolError("Frame payload exceeds the maximum allowed size.")
        }
        frm.payload = try await transport.read(length: Int(len))
        for index in 0..<len {
            frm.payload[Int(index)] ^= mask[Int(index % 4)]
        }
        return frm
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

public func == (lhs: WebSocketSession, rhs: WebSocketSession) -> Bool {
    return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
}
