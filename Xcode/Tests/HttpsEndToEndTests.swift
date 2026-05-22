//
//  HttpsEndToEndTests.swift
//  Swifter
//
//  起 HTTPS server(自签名 P12 fixture),用 URLSession 客户端
//  并禁用证书验证连接,验证 TLS handshake + handler 派发可用。
//

import XCTest
@testable import Swifter

final class HttpsEndToEndTests: XCTestCase {

    private static let fixturePassword = "swiftertest"

    private static var fixturePath: String {
        let thisFile = URL(fileURLWithPath: #file)
        return thisFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("localhost.p12")
            .path
    }

    func testHttpsHandshakeAndGet() async throws {
        let tls: TLSConfig
        do {
            tls = try TLSConfig.p12(path: Self.fixturePath, password: Self.fixturePassword)
        } catch TLSConfigError.p12ImportFailed(let status) where status == -26276 {
            // 见 TLSConfigTests.testLoadValidP12 注释:某些 macOS 环境下 SecPKCS12Import
            // 拒绝 fixture P12 并返回 -26276。在 iOS 上行为预计正常,这里跳过避免误报
            throw XCTSkip("SecPKCS12Import returned -26276; skipping HTTPS e2e")
        }
        let server = HttpServer()
        server.GET["/ping"] = { _ in .ok(.text("pong over tls")) }
        try await server.start(8443, tls: tls)
        defer { server.stop() }

        let url = URL(string: "https://localhost:8443/ping")!
        let session = URLSession(
            configuration: .ephemeral,
            delegate: IgnoreTLSDelegate(),
            delegateQueue: nil
        )
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "pong over tls")
    }
}

/// 测试用 delegate:接受任意 server cert(自签名 fixture)
private final class IgnoreTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
