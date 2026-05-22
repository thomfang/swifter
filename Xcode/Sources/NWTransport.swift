//
//  NWTransport.swift
//  Swifter
//
//  HttpTransport 的 NWConnection 实现 —— 把 callback-style receive/send
//  封进 async/await,并维护跨 receive 调用的 byte buffer。
//

import Foundation
import Network

/// 基于 NWConnection 的 HttpTransport 实现。
/// 单一 connection 由单一 Task 消费,actor 保证 read buffer 并发安全。
public actor NWTransport: HttpTransport {

    private let connection: NWConnection
    private var readBuffer: [UInt8] = []
    private var isClosed = false

    /// 一次 receive 最大字节数,够大可以减少 read 单字节场景的 callback 次数
    private static let receiveChunk = 64 * 1024

    public init(_ connection: NWConnection) {
        self.connection = connection
    }

    public nonisolated var peername: String? {
        switch connection.endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port.rawValue)"
        case .service(let name, _, _, _):
            return name
        case .unix(let path):
            return path
        case .url(let url):
            return url.absoluteString
        case .opaque:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Read

    public func read() async throws -> UInt8 {
        if readBuffer.isEmpty {
            try await fillBuffer()
        }
        return readBuffer.removeFirst()
    }

    public func read(length: Int) async throws -> [UInt8] {
        if length <= 0 { return [] }
        while readBuffer.count < length {
            try await fillBuffer()
        }
        let out = Array(readBuffer.prefix(length))
        readBuffer.removeFirst(length)
        return out
    }

    public func readLine() async throws -> String {
        var bytes: [UInt8] = []
        while true {
            let byte = try await read()
            // HTTP/1.1 以 CRLF 为行终止,这里跟现状 HttpParser 行为一致:
            // 跳过 \r,以 \n 为终止符
            if byte == 0x0A { // '\n'
                break
            }
            if byte == 0x0D { // '\r'
                continue
            }
            bytes.append(byte)
        }
        guard let str = String(bytes: bytes, encoding: .utf8) else {
            throw HttpTransportError.invalidData
        }
        return str
    }

    /// 从 connection 拉一批字节填进 readBuffer
    private func fillBuffer() async throws {
        if isClosed {
            throw HttpTransportError.disconnected
        }
        let chunk = try await receiveChunkOnce()
        if chunk.isEmpty {
            // EOF / 对端关闭
            isClosed = true
            throw HttpTransportError.disconnected
        }
        readBuffer.append(contentsOf: chunk)
    }

    /// 包一次 NWConnection.receive 为 async
    private func receiveChunkOnce() async throws -> [UInt8] {
        let conn = connection
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunk) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: HttpTransportError.underlying(error.localizedDescription))
                    return
                }
                if let data = data, !data.isEmpty {
                    cont.resume(returning: [UInt8](data))
                    return
                }
                if isComplete {
                    cont.resume(returning: [])
                    return
                }
                // 无数据 + 未完成 + 无错误:理论上 receive 不会进这里,fallback 当 EOF
                cont.resume(returning: [])
            }
        }
    }

    // MARK: - Write

    public func write(_ data: ArraySlice<UInt8>) async throws {
        if isClosed {
            throw HttpTransportError.disconnected
        }
        try await sendData(Data(data))
    }

    private func sendData(_ data: Data) async throws {
        let conn = connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: HttpTransportError.underlying(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - Close

    public nonisolated func close() {
        // cancel 是幂等的,直接调即可;actor 状态在下次 read/write 触发 disconnected
        connection.cancel()
    }
}
