//
//  HttpParser.swift
//  Swifter
// 
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation

enum HttpParserError: Error, Equatable {
    case invalidStatusLine(String)
    case negativeContentLength
    /// 声明的 Content-Length 超过 maxRequestBodySize —— 调用方应回 413 并关连接
    case requestBodyTooLarge(Int)
}

public class HttpParser {

    /// 请求体上限(字节)。防御恶意/超大 Content-Length 把 read buffer 撑爆导致 OOM。
    /// 默认 50MB,调用方可按需调整。
    public var maxRequestBodySize: Int = 50 * 1024 * 1024

    public init() { }

    func supportsKeepAlive(_ headers: [String: String]) -> Bool {
        if let value = headers["connection"] {
            return "keep-alive" == value.trimmingCharacters(in: .whitespaces)
        }
        return false
    }

    // MARK: - Async path (HttpTransport)

    /// 基于 HttpTransport 的 async 状态机版本。
    /// 与同步版本(Socket) 行为完全一致:status line / headers / 可选 body(Content-Length)。
    /// 不支持 Transfer-Encoding: chunked(与上游一致,out of scope)。
    public func readHttpRequest(_ transport: HttpTransport) async throws -> HttpRequest {
        let statusLine = try await transport.readLine()
        let statusLineTokens = statusLine.components(separatedBy: " ")
        if statusLineTokens.count < 3 {
            throw HttpParserError.invalidStatusLine(statusLine)
        }
        let request = HttpRequest()
        request.method = statusLineTokens[0]
        let encodedPath = statusLineTokens[1].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? statusLineTokens[1]
        let urlComponents = URLComponents(string: encodedPath)
        request.path = urlComponents?.path ?? ""
        request.queryParams = urlComponents?.queryItems?.map { ($0.name, $0.value ?? "") } ?? []
        request.headers = try await readHeaders(transport)
        if let contentLength = request.headers["content-length"], let contentLengthValue = Int(contentLength) {
            // 防御:负长度会让上游 UnsafeMutableBufferPointer 越界,parser 直接拒绝
            guard contentLengthValue >= 0 else {
                throw HttpParserError.negativeContentLength
            }
            // 防御:超大 Content-Length 会让 read(length:) 把 buffer 撑爆 OOM。
            // 不读 body,直接抛错让 IO 层回 413 并关连接。
            guard contentLengthValue <= maxRequestBodySize else {
                throw HttpParserError.requestBodyTooLarge(contentLengthValue)
            }
            request.body = try await transport.read(length: contentLengthValue)
        }
        return request
    }

    private func readHeaders(_ transport: HttpTransport) async throws -> [String: String] {
        var headers = [String: String]()
        while true {
            let headerLine = try await transport.readLine()
            if headerLine.isEmpty { break }
            let headerTokens = headerLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            if let name = headerTokens.first, let value = headerTokens.last {
                headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return headers
    }
}
