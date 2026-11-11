import XCTest
import Network
@testable import Swifter

final class HttpServerIOLifecycleTests: XCTestCase {
    func testConcurrentStartsShareReadinessAndCancelOnlyTheirOwnWaiter() async throws {
        let server = makeServer()
        let gate = LifecycleGate()
        let created = LifecycleValue(0)
        var hooks = HttpServerIO.ListenerLifecycleTestHooks()
        hooks.beforeReady = { gate.blockOnce(id: $0) }
        hooks.didCreateListener = { _, _ in created.update { $0 += 1 } }
        server.listenerLifecycleTestHooks = hooks
        let starts = (0..<16).map { _ in start(server) }
        defer { gate.release(); starts.forEach { $0.task.cancel() }; server.stop() }
        await fulfillment(of: [gate.entered], timeout: 5)
        try await wait { server.pendingStartCount == starts.count }
        starts[0].task.cancel()
        await fulfillment(of: [starts[0].completed], timeout: 5)
        assertCancelled(starts[0])
        XCTAssertEqual(server.pendingStartCount, 15)
        gate.release()
        await fulfillment(of: starts.dropFirst().map(\.completed), timeout: 5)
        for operation in starts.dropFirst() { try operation.result.read().get() }
        XCTAssertEqual(created.read(), 1)
        try await verifyPayload(server)
    }

    func testStopCompletesWaitersAndOldReadyCannotAffectSamePortRestart() async throws {
        let server = makeServer()
        let gate = LifecycleGate()
        let listeners = LifecycleValue<[UUID: NWListener]>([:])
        let cancelled = expectation(description: "Native listener cancellation completed")
        var hooks = HttpServerIO.ListenerLifecycleTestHooks()
        hooks.beforeReady = { gate.blockOnce(id: $0) }
        hooks.afterReady = { gate.processed(id: $0) }
        hooks.didCancelListener = { id in if id == gate.id { cancelled.fulfill() } }
        hooks.didCreateListener = { id, listener in listeners.update { $0[id] = listener } }
        server.listenerLifecycleTestHooks = hooks
        let old = start(server)
        defer { gate.release(); old.task.cancel(); server.stop() }
        await fulfillment(of: [gate.entered], timeout: 5)
        let oldID = try XCTUnwrap(gate.id)
        let port = try XCTUnwrap(listeners.read()[oldID]?.port?.rawValue)
        let stopped = expectation(description: "Main-thread stop returns while readiness callback is blocked")
        DispatchQueue.main.async { server.stop(); stopped.fulfill() }
        await fulfillment(of: [stopped, old.completed], timeout: 5)
        assertCancelled(old)
        XCTAssertEqual(server.state, .stopped)
        XCTAssertThrowsError(try server.port())
        let replacement = start(server, port: port)
        await fulfillment(of: [replacement.completed, cancelled], timeout: 5)
        try replacement.result.read().get()
        XCTAssertEqual(try server.port(), Int(port))
        gate.release()
        await fulfillment(of: [gate.didProcess], timeout: 5)
        XCTAssertTrue(server.operating)
        try await verifyPayload(server)
    }

    func testCancellationBeforeBeginAndBeforeReadyCannotReviveListener() async throws {
        for beforeBegin in [true, false] {
            let server = makeServer()
            let gate = LifecycleGate()
            let created = LifecycleValue(0)
            var hooks = HttpServerIO.ListenerLifecycleTestHooks()
            if beforeBegin { hooks.beforeBegin = { gate.blockOnce() } }
            else { hooks.beforeReady = { gate.blockOnce(id: $0) } }
            hooks.didCreateListener = { _, _ in created.update { $0 += 1 } }
            server.listenerLifecycleTestHooks = hooks
            let operation = start(server)
            defer { gate.release(); operation.task.cancel(); server.stop() }
            await fulfillment(of: [gate.entered], timeout: 5)
            operation.task.cancel()
            XCTAssertEqual(server.state, .stopped)
            if beforeBegin { XCTAssertEqual(created.read(), 0) }
            else {
                // A cancelled readiness waiter finishes without waiting for its callback.
                await fulfillment(of: [operation.completed], timeout: 5)
                assertCancelled(operation)
            }
            gate.release()
            if beforeBegin {
                await fulfillment(of: [operation.completed], timeout: 5)
                assertCancelled(operation)
                XCTAssertEqual(created.read(), 0)
            }
            XCTAssertThrowsError(try server.port())
        }
    }

    func testSynchronousTimeoutRetiresOnlyItsUndeliveredGeneration() async throws {
        for replaceBeforeTimeout in [false, true] {
            let server = makeServer()
            let gate = LifecycleGate()
            var hooks = HttpServerIO.ListenerLifecycleTestHooks()
            hooks.beforeSynchronousSignal = { gate.blockOnce() }
            hooks.synchronousTimeout = .milliseconds(300)
            server.listenerLifecycleTestHooks = hooks
            let result = LifecycleValue<Result<Void, Error>>(.success(()))
            let finished = expectation(description: "Synchronous timeout completed")
            DispatchQueue.global(qos: .userInitiated).async {
                result.update { value in
                    do { try server.start(0); value = .success(()) }
                    catch { value = .failure(error) }
                }
                finished.fulfill()
            }
            defer { gate.release(); server.stop() }
            await fulfillment(of: [gate.entered], timeout: 5)
            XCTAssertTrue(server.operating)
            if replaceBeforeTimeout {
                server.stop()
                try await server.startAsync(0)
            }
            await fulfillment(of: [finished], timeout: 5)
            if case .success = result.read() { XCTFail("Expected the injected synchronous deadline") }
            XCTAssertEqual(server.operating, replaceBeforeTimeout)
            gate.release()
            if replaceBeforeTimeout { try await verifyPayload(server) }
            else { XCTAssertThrowsError(try server.port()) }
        }
    }

    func testStoppedGenerationCannotDispatchBufferedRequestAfterRestart() async throws {
        let server = makeServer()
        let gate = LifecycleGate()
        let dispatched = LifecycleValue(0)
        let oldFinished = expectation(description: "Old connection finished after its dispatch boundary")
        let cancelled = expectation(description: "Old native listener cancellation completed")
        server.POST["/old"] = { _ in dispatched.update { $0 += 1 }; return .ok(.text("stale")) }
        var hooks = HttpServerIO.ListenerLifecycleTestHooks()
        hooks.beforeRequestDispatch = { id, path in
            if path == "/old" { gate.blockOnce(id: id) }
        }
        hooks.didFinishConnection = { id in
            if id == gate.id { oldFinished.fulfill() }
        }
        hooks.didCancelListener = { id in if id == gate.id { cancelled.fulfill() } }
        server.listenerLifecycleTestHooks = hooks
        try await server.startAsync(0)
        let port = try server.port()
        let session = URLSession(configuration: .ephemeral)
        let oldCompleted = expectation(description: "Stopped old HTTP request completed")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/old")!)
        request.httpMethod = "POST"
        let task = session.dataTask(with: request) { _, _, _ in oldCompleted.fulfill() }
        task.resume()
        defer { gate.release(); task.cancel(); session.invalidateAndCancel(); server.stop() }
        await fulfillment(of: [gate.entered], timeout: 5)
        server.stop()
        try await server.startAsync(in_port_t(port))
        gate.release()
        await fulfillment(of: [oldFinished, oldCompleted, cancelled], timeout: 5)
        XCTAssertEqual(dispatched.read(), 0, "An old parsed request must not reach a new generation's handlers")
        try await verifyPayload(server)
    }

    func testPendingSamePortRestartWaitsForRetirementAndCanBeCancelled() async throws {
        let server = makeServer()
        let gate = LifecycleGate()
        let created = LifecycleValue(0)
        var hooks = HttpServerIO.ListenerLifecycleTestHooks()
        hooks.beforeCancellationReceipt = { gate.blockOnce(id: $0) }
        hooks.didCreateListener = { _, _ in created.update { $0 += 1 } }
        server.listenerLifecycleTestHooks = hooks
        try await server.startAsync(0)
        let port = in_port_t(try server.port())
        defer { gate.release(); server.stop() }
        server.stop()
        await fulfillment(of: [gate.entered], timeout: 5)
        let cancelled = start(server, port: port)
        try await wait { server.pendingStartCount == 1 }
        XCTAssertEqual(created.read(), 1, "Retirement must finish before another native listener is created")
        cancelled.task.cancel()
        await fulfillment(of: [cancelled.completed], timeout: 5)
        assertCancelled(cancelled)
        let replacement = start(server, port: port)
        try await wait { server.pendingStartCount == 1 }
        gate.release()
        await fulfillment(of: [replacement.completed], timeout: 5)
        try replacement.result.read().get()
        XCTAssertEqual(created.read(), 2)
        XCTAssertEqual(try server.port(), Int(port))
        try await verifyPayload(server)
    }

    func testNativeCancellationCompletesWaiterWithoutReadyPublication() async throws {
        let server = makeServer()
        let gate = LifecycleGate()
        let listener = LifecycleValue<NWListener?>(nil)
        var hooks = HttpServerIO.ListenerLifecycleTestHooks()
        hooks.beforeReady = { gate.blockOnce(id: $0) }
        hooks.didCreateListener = { _, value in listener.update { $0 = value } }
        server.listenerLifecycleTestHooks = hooks
        let operation = start(server)
        defer { gate.release(); operation.task.cancel(); server.stop() }
        await fulfillment(of: [gate.entered], timeout: 5)
        try XCTUnwrap(listener.read()).cancel()
        await fulfillment(of: [operation.completed], timeout: 5)
        assertCancelled(operation)
        XCTAssertEqual(server.state, .stopped)
        XCTAssertThrowsError(try server.port())
    }

    private func makeServer() -> HttpServer {
        let server = HttpServer()
        server.GET["/ping"] = { _ in .ok(.text("owned-live-generation")) }
        return server
    }

    private func verifyPayload(_ server: HttpServer) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(try server.port())/ping")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "owned-live-generation")
    }

    private struct StartOperation {
        let task: Task<Void, Never>
        let completed: XCTestExpectation
        let result: LifecycleValue<Result<Void, Error>>
    }

    private func start(_ server: HttpServer, port: in_port_t = 0) -> StartOperation {
        let completed = expectation(description: "Listener start completed")
        let result = LifecycleValue<Result<Void, Error>>(.success(()))
        let task = Task.detached {
            let outcome: Result<Void, Error>
            do { try await server.startAsync(port); outcome = .success(()) }
            catch { outcome = .failure(error) }
            result.update { $0 = outcome }
            completed.fulfill()
        }
        return StartOperation(task: task, completed: completed, result: result)
    }

    private func assertCancelled(_ operation: StartOperation, file: StaticString = #filePath, line: UInt = #line) {
        switch operation.result.read() {
        case .success: XCTFail("Expected cancellation", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Lifecycle boundary did not become ready")
        throw CancellationError()
    }
}

private final class LifecycleValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&value) } }
}

private final class LifecycleGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Controlled native lifecycle boundary reached")
    let didProcess = XCTestExpectation(description: "Old ready callback processed")
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var blocked = false
    private var blockedID: UUID?
    private var processingReported = false
    var id: UUID? { lock.withLock { blockedID } }

    func blockOnce(id: UUID? = nil) {
        let shouldBlock = lock.withLock { () -> Bool in
            guard !blocked else { return false }
            blocked = true
            blockedID = id
            return true
        }
        guard shouldBlock else { return }
        entered.fulfill()
        _ = releaseSemaphore.wait(timeout: .now() + .seconds(5))
    }

    func processed(id: UUID) {
        let shouldReport = lock.withLock { () -> Bool in
            guard blockedID == id, !processingReported else { return false }
            processingReported = true
            return true
        }
        if shouldReport { didProcess.fulfill() }
    }

    func release() { releaseSemaphore.signal() }
}
