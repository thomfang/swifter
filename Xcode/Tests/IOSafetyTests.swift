//
//  IOSafetyTests.swift
//  Swifter
//
//  Created by Brian Gerstle on 8/20/16.
//  Copyright © 2016 Damian Kołakowski. All rights reserved.
//

import XCTest
@testable import Swifter

class IOSafetyTests: XCTestCase {
    var server: HttpServer!
    var urlSession: URLSession!

    override func setUp() {
        super.setUp()
        server = HttpServer.pingServer()
        urlSession = URLSession(configuration: .default)
    }

    override func tearDown() {
        if let server = server, server.operating {
            server.stop()
        }
        urlSession = nil
        server = nil
        super.tearDown()
    }

    func testStopWithActiveConnections() async {
        // 缩小迭代次数 —— NWListener 启停比 BSD socket 慢一些;旧测试 101*101 在新底层下
        // 会让单测时间膨胀且接近系统连接数上限
        for cpt in 0..<5 {
            server = HttpServer.pingServer()
            do {
                let port = UInt16(9100 + cpt)
                try await server.start(port)
                let hostURL = URL(string: "http://localhost:\(port)")!
                XCTAssertFalse(urlSession.retryPing(hostURL: hostURL))
                for _ in 0..<10 {
                    urlSession.pingTask(hostURL: hostURL) { _, _, _ in }.resume()
                }
                server.stop()
            } catch let error {
                XCTFail("\(cpt): \(error)")
            }
        }
    }
}
