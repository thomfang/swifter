//
//  ServerThreadingTests.swift
//  Swifter
//
//  Created by Victor Sigler on 4/22/19.
//  Copyright © 2019 Damian Kołakowski. All rights reserved.
//

import XCTest
@testable import Swifter

class ServerThreadingTests: XCTestCase {

    var server: HttpServer!

    override func setUp() {
        super.setUp()
        server = HttpServer()
    }

    override func tearDown() {
        if let server = server, server.operating {
            server.stop()
        }
        server = nil
        super.tearDown()
    }

    func testShouldHandleTheRequestInDifferentTimeIntervals() async {

        let path = "/a/:b/c"
        let queue = DispatchQueue(label: "com.swifter.threading")

        server.GET[path] = { .ok(.htmlBody("You asked for " + $0.path)) }

        let requestExpectation = expectation(description: "Request should finish.")
        requestExpectation.expectedFulfillmentCount = 3

        do {
            try await server.start(8081)
            let hostURL = URL(string: "http://localhost:8081")!

            (1...3).forEach { index in
                queue.asyncAfter(deadline: .now() + .milliseconds(index * 200)) {
                    let task = URLSession.shared.executeAsyncTask(hostURL: hostURL, path: path) { (_, response, _ ) in
                        let statusCode = (response as? HTTPURLResponse)?.statusCode
                        XCTAssertNotNil(statusCode)
                        XCTAssertEqual(statusCode, 200, "\(hostURL)")
                        requestExpectation.fulfill()
                    }
                    task.resume()
                }
            }
        } catch let error {
            XCTFail("\(error)")
        }

        await fulfillment(of: [requestExpectation], timeout: 10)
    }

    func testShouldHandleTheSameRequestConcurrently() async {

        let path = "/a/:b/c"
        server.GET[path] = { .ok(.htmlBody("You asked for " + $0.path)) }

        let requestExpectation = expectation(description: "Should handle the request concurrently")
        requestExpectation.expectedFulfillmentCount = 3

        do {
            try await server.start(8082)
            let hostURL = URL(string: "http://localhost:8082")!

            DispatchQueue.concurrentPerform(iterations: 3) { _ in
                let task = URLSession.shared.executeAsyncTask(hostURL: hostURL, path: path) { (_, response, _ ) in
                    let statusCode = (response as? HTTPURLResponse)?.statusCode
                    XCTAssertNotNil(statusCode)
                    XCTAssertEqual(statusCode, 200)
                    requestExpectation.fulfill()
                }
                task.resume()
            }
        } catch let error {
            XCTFail("\(error)")
        }

        await fulfillment(of: [requestExpectation], timeout: 15)
    }
}

extension URLSession {

    func executeAsyncTask(
        hostURL: URL = defaultLocalhost,
        path: String,
        completionHandler handler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        return self.dataTask(with: hostURL.appendingPathComponent(path), completionHandler: handler)
    }
}
