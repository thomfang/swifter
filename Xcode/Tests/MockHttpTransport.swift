//
//  MockHttpTransport.swift
//  Swifter
//
//  in-memory HttpTransport,用于 parser / handler 单元测试。
//  read 端预填入字节;write 端记入 sink。
//

import Foundation
@testable import Swifter

actor MockHttpTransport: HttpTransport {

    private var inbox: [UInt8]
    private(set) var sink: [UInt8] = []
    private var closed = false

    init(_ string: String) {
        self.inbox = [UInt8](string.utf8)
    }

    init(_ bytes: [UInt8]) {
        self.inbox = bytes
    }

    nonisolated var peername: String? { "mock" }

    func read() async throws -> UInt8 {
        if closed && inbox.isEmpty {
            throw HttpTransportError.disconnected
        }
        guard !inbox.isEmpty else {
            throw HttpTransportError.disconnected
        }
        return inbox.removeFirst()
    }

    func read(length: Int) async throws -> [UInt8] {
        if length <= 0 { return [] }
        if inbox.count < length {
            throw HttpTransportError.disconnected
        }
        let out = Array(inbox.prefix(length))
        inbox.removeFirst(length)
        return out
    }

    func readLine() async throws -> String {
        var bytes: [UInt8] = []
        while true {
            if inbox.isEmpty {
                throw HttpTransportError.disconnected
            }
            let b = inbox.removeFirst()
            if b == 0x0A { break }
            if b == 0x0D { continue }
            bytes.append(b)
        }
        guard let s = String(bytes: bytes, encoding: .utf8) else {
            throw HttpTransportError.invalidData
        }
        return s
    }

    func write(_ data: ArraySlice<UInt8>) async throws {
        sink.append(contentsOf: data)
    }

    nonisolated func close() {
        Task { await self.markClosed() }
    }

    private func markClosed() { closed = true }

    /// 测试便利:把剩余 inbox 全部读完(parser 不会再用 read)
    func remainingInbox() -> [UInt8] { inbox }
}
