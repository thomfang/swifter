//
//  HttpTransport.swift
//  Swifter
//
//  HTTP I/O 层抽象 —— 把"读字节 / 写字节 / 关连接"封进 async 接口,
//  让 HttpParser 与 HttpServerIO 不直接依赖具体网络底层(NWConnection 或测试 mock)。
//

import Foundation

public enum HttpTransportError: Error, Sendable {
    /// 对端断开 / EOF
    case disconnected
    /// 读到非法 UTF-8 等数据
    case invalidData
    /// 读超时
    case timeout
    /// 底层错误(NWConnection / mock)
    case underlying(String)
}

/// async byte stream 抽象 —— 实现者负责跨多次底层 receive 拼接 byte buffer。
/// 不限定 AnyObject,允许 actor 实现。
public protocol HttpTransport: Sendable {

    /// 读单字节,EOF 时抛 HttpTransportError.disconnected
    func read() async throws -> UInt8

    /// 精确读 length 字节;长度不足以 EOF 时抛 disconnected
    func read(length: Int) async throws -> [UInt8]

    /// 读到 '\n' 为止,丢弃 '\r' 与终止 '\n';返回 UTF-8 字符串
    /// 非 UTF-8 字节抛 invalidData
    func readLine() async throws -> String

    /// 写入 byte slice
    func write(_ data: ArraySlice<UInt8>) async throws

    /// 写入 Data
    func write(_ data: Data) async throws

    /// 写入 UTF-8 字符串
    func write(_ utf8: String) async throws

    /// 对端地址(诊断用,不可解析时返回 nil)
    var peername: String? { get }

    /// 关闭底层连接(幂等)
    func close()
}

public extension HttpTransport {
    func write(_ data: Data) async throws {
        try await write(ArraySlice([UInt8](data)))
    }

    func write(_ utf8: String) async throws {
        try await write(ArraySlice([UInt8](utf8.utf8)))
    }
}
