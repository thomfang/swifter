//
//  TLSConfigTests.swift
//  Swifter
//
//  TLSConfig.p12 加载行为单元测试。
//  Fixture: Xcode/Tests/Fixtures/localhost.p12,密码 "swiftertest"
//

import XCTest
@testable import Swifter

final class TLSConfigTests: XCTestCase {

    private static let fixturePassword = "swiftertest"

    private static var fixturePath: String {
        // 测试运行时 cwd 通常是 swift-build 输出目录;通过 #file 反推 fixture 路径
        let thisFile = URL(fileURLWithPath: #file)
        return thisFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("localhost.p12")
            .path
    }

    func testLoadValidP12() throws {
        let config = try TLSConfig.p12(path: Self.fixturePath, password: Self.fixturePassword)
        // tlsOptions 是包内可见的属性,这里只验证不抛错
        XCTAssertNotNil(config.tlsOptions)
    }

    func testWrongPasswordThrowsImportFailed() {
        do {
            _ = try TLSConfig.p12(path: Self.fixturePath, password: "wrong-password")
            XCTFail("Expected p12ImportFailed")
        } catch TLSConfigError.p12ImportFailed(let status) {
            // errSecAuthFailed = -25293,errSecDecode = -26275 等都可能
            XCTAssertNotEqual(status, errSecSuccess)
        } catch {
            XCTFail("Expected p12ImportFailed, got \(error)")
        }
    }

    func testMissingFileThrowsFileNotFound() {
        do {
            _ = try TLSConfig.p12(path: "/tmp/this-does-not-exist-\(UUID()).p12", password: "x")
            XCTFail("Expected p12FileNotFound")
        } catch TLSConfigError.p12FileNotFound {
            // expected
        } catch {
            XCTFail("Expected p12FileNotFound, got \(error)")
        }
    }
}
