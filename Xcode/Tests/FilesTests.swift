//
//  FilesTests.swift
//  Swifter
//
//  Created by Michael Enger on 02/09/2021.
//  Copyright © 2021 Damian Kołakowski. All rights reserved.
//

import XCTest
@testable import Swifter

class FilesTests: XCTestCase {
    let temporaryDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let temporaryFileName = UUID().uuidString + ".png"

    override func setUp() {
        super.setUp()

        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent(temporaryFileName)
        let data = "This is a file"
        do {
            try data.write(to: temporaryFileURL, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            XCTFail("Failed to create temporary file")
        }
    }

    override func tearDown() {
        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent(temporaryFileName)
        do {
            try FileManager.default.removeItem(at: temporaryFileURL)
        } catch {
            // no worries
        }
        
        super.tearDown()
    }
    
    func testShareFile() {
        let request = HttpRequest()
        let closure = shareFile(temporaryDirectoryURL.appendingPathComponent(temporaryFileName).path)
        let result = closure(request)
        let headers = result.headers()

        XCTAssert(result.statusCode == 200)
        XCTAssert(headers["Content-Type"] == "image/png")
        XCTAssert(headers["Content-Length"] == "14")
    }
    
    func testShareFileNotFound() {
        let request = HttpRequest()
        let closure = shareFile(temporaryDirectoryURL.appendingPathComponent("does_not_exist").path)
        let result = closure(request)

        XCTAssert(result.statusCode == 404)
    }

    func testShareFilesFromDirectory() {
        let request = HttpRequest()
        request.params = ["path": temporaryFileName]
        let closure = shareFilesFromDirectory(temporaryDirectoryURL.path)
        let result = closure(request)
        let headers = result.headers()

        XCTAssert(result.statusCode == 200)
        XCTAssert(headers["Content-Type"] == "image/png")
        XCTAssert(headers["Content-Length"] == "14")
    }
    
    func testShareFilesFromDirectoryFileNotFound() {
        let request = HttpRequest()
        request.params = ["path": "does_not_exist.wav"]

        let closure = shareFilesFromDirectory(temporaryDirectoryURL.path)
        let result = closure(request)

        XCTAssert(result.statusCode == 404)
    }
    
    func testDirectoryBrowser() {
        let request = HttpRequest()
        request.params = ["path": ""]
        let closure = directoryBrowser(temporaryDirectoryURL.path)
        let result = closure(request)

        XCTAssert(result.statusCode == 200)
    }
    
    func testDirectoryBrowserNotFound() {
        let request = HttpRequest()
        request.params = ["path": "does/not/exist"]
        let closure = directoryBrowser(temporaryDirectoryURL.path)
        let result = closure(request)

        XCTAssert(result.statusCode == 404)
    }

    /// fopen 在目录上不会失败 —— 没有这道防御,shareFile 给目录返回 200 + 空 body。
    /// 修复后,目录路径应该被 shareFile 当 404 处理。
    func testShareFileRejectsDirectory() {
        let request = HttpRequest()
        let closure = shareFile(temporaryDirectoryURL.path)
        let result = closure(request)

        XCTAssertEqual(result.statusCode, 404)
    }

    /// 同样的防御对 shareFilesFromDirectory:path param 命中目录时应返回 404,
    /// 不能把目录当文件 stream 出去
    func testShareFilesFromDirectoryRejectsDirectoryHit() {
        // 在 tmp 下创建一个子目录,确保命中
        let subdirURL = temporaryDirectoryURL.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: subdirURL) }

        let request = HttpRequest()
        request.params = ["path": subdirURL.lastPathComponent]
        let closure = shareFilesFromDirectory(temporaryDirectoryURL.path)
        let result = closure(request)

        XCTAssertEqual(result.statusCode, 404)
    }
}
