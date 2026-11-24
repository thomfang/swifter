//
//  HttpServerIO.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation
import Network

/// 上层(scripting-ios LocalServer 等)关心的连接生命周期事件 —— 切到
/// transport 抽象之后,delegate 拿到的不是底层 socket,而是已经 upgrade
/// 完成的 WebSocket transport(handleConnection 在交付 session 前回调)。
public protocol HttpServerIODelegate: AnyObject, Sendable {
    func transportConnectionReceived(_ transport: HttpTransport)
}

open class HttpServerIO: @unchecked Sendable {

    public weak var delegate: HttpServerIODelegate?

    public enum HttpServerIOState: Int32 {
        case starting
        case running
        case stopping
        case stopped
    }

    // Listener publication and connection admission share a short critical section.
    // Readiness is awaited after releasing it, so stop never waits for a bind.
    private let lifecycleLock = NSLock()
    private var stateValue: Int32 = HttpServerIOState.stopped.rawValue
    private var stopEpoch: UInt64 = 0
    private var attempt: ListenerAttempt?
    private var retiringListeners: [UUID: NWListener] = [:]
    private var pendingStarts: [UUID: PendingStart] = [:]

    public private(set) var state: HttpServerIOState {
        get {
            lifecycleLock.lock(); defer { lifecycleLock.unlock() }
            return HttpServerIOState(rawValue: stateValue)!
        }
        set {
            lifecycleLock.lock(); stateValue = newValue.rawValue; lifecycleLock.unlock()
        }
    }

    public var operating: Bool { return self.state == .running }

    /// String representation of the IPv4 address to receive requests from.
    /// 当 forceIPv4 = true 时使用;否则用 listenAddressIPv6。
    public var listenAddressIPv4: String?

    /// String representation of the IPv6 address to receive requests from.
    public var listenAddressIPv6: String?

    /// An opt-in connection handler for consumers that own HTTP framing. Set before starting.
    public var httpConnectionHandler: (@Sendable (NWTransport) async -> Void)? {
        get { lifecycleLock.withLock { connectionHandler } }
        set { lifecycleLock.withLock { connectionHandler = newValue } }
    }
    private var connectionHandler: (@Sendable (NWTransport) async -> Void)?

    /// 请求体上限(字节),建连时传给该连接的 HttpParser。默认 50MB。
    public var maxRequestBodySize: Int = 50 * 1024 * 1024

    /// WebSocket 单帧 / 分片消息累积上限(字节)。建连时由 websocket handler 读取,
    /// 因此 start 时设定的值对之后建立的连接生效,与 registerWebsocket 的调用顺序无关。默认 16MB。
    public var maxWebSocketPayloadSize: Int = 16 * 1024 * 1024

    /// All entries belong to the current attempt. Old callbacks cannot admit new entries.
    private var connections: [UUID: HttpTransport] = [:]

    /// listener 启动后报告的本地端口 —— start 完成时已经 ready,有值
    private var resolvedPort: UInt16?

    struct ListenerLifecycleTestHooks: Sendable {
        var beforeBegin: (@Sendable () -> Void)?
        var beforeReady: (@Sendable (UUID) -> Void)?
        var afterReady: (@Sendable (UUID) -> Void)?
        var didCancelListener: (@Sendable (UUID) -> Void)?
        var beforeCancellationReceipt: (@Sendable (UUID) -> Void)?
        var didCreateListener: (@Sendable (UUID, NWListener) -> Void)?
        var beforeSynchronousSignal: (@Sendable () -> Void)?
        var beforeRequestDispatch: (@Sendable (UUID, String) -> Void)?
        var didFinishConnection: (@Sendable (UUID) -> Void)?
        var synchronousTimeout: DispatchTimeInterval?
    }

    private var testHooks: ListenerLifecycleTestHooks?
    var listenerLifecycleTestHooks: ListenerLifecycleTestHooks? {
        get { lifecycleLock.withLock { testHooks } }
        set { lifecycleLock.withLock { testHooks = newValue } }
    }

    var pendingStartCount: Int {
        lifecycleLock.withLock { (attempt?.requests.count ?? 0) + pendingStarts.count }
    }

    private final class StartRequest: @unchecked Sendable {
        let id = UUID()
        let completion = ListenerReadyAwaiter()
        // Protected by lifecycleLock, including cancellation before admission.
        var cancelled = false
        weak var attempt: ListenerAttempt?
    }

    private final class ListenerAttempt: @unchecked Sendable {
        let id = UUID()
        let listener: NWListener
        let queue = DispatchQueue(label: "swifter.httpserverio.listener", qos: .userInitiated)
        var requests: [UUID: StartRequest] = [:]
        var hasDeliveredStarter = false

        init(listener: NWListener) { self.listener = listener }
    }

    private struct PendingStart {
        let request: StartRequest
        let epoch: UInt64
        let port: in_port_t
        let forceIPv4: Bool
        let tls: TLSConfig?
    }

    private struct Shutdown {
        let requests: [StartRequest]
        let transports: [HttpTransport]

        func finish(_ error: Error) {
            for request in requests { request.completion.fulfill(.failure(error)) }
            for transport in transports { transport.close() }
        }
    }

    public init() {}

    deinit {
        stop()
    }

    public func port() throws -> Int {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard let resolvedPort = resolvedPort else {
            throw HttpServerError.notRunning
        }
        return Int(resolvedPort)
    }

    public func isIPv4() throws -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        // NWListener 同时接受 v4/v6;此处保留 API 形态以兼容旧调用,统一返回 forceIPv4 时的语义
        return forceIPv4Active
    }

    /// 内部 flag —— 记录上次 start 是否 forceIPv4
    private var forceIPv4Active: Bool = false

    /// Sync 包装 —— 跑 async start 然后 semaphore 等结果。
    /// 用于无 async 上下文的调用方(scripting-ios JSHttpServer 等)。等待时间通常 < 100ms。
    /// async 调用方应直接调用 `startAsync(_:forceIPv4:tls:)` 避免阻塞当前线程。
    public func start(_ port: in_port_t = 8080, forceIPv4: Bool = false, tls: TLSConfig? = nil) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        let request = StartRequest()
        // sync 调用方可能在 main thread (UserInteractive QoS) 等 semaphore;
        // Task.detached 默认走 .medium,会触发 priority inversion 告警。
        // 把 Task 提升到 .userInitiated,与 sync caller 的优先级匹配。
        let task = Task.detached(priority: .userInitiated) { [box, self] in
            do {
                try await self.startOperation(request, port: port, forceIPv4: forceIPv4, tls: tls)
                self.listenerLifecycleTestHooks?.beforeSynchronousSignal?()
            } catch {
                self.cancel(request)
                box.error = error
            }
            semaphore.signal()
        }
        // 加超时兜底:startAsync 会在 .ready/.failed/.waiting 都 fulfill,正常应立即返回;
        // 此处防御未知挂起,避免 JS 主线程调 start() 时永久阻塞 → watchdog 崩。
        let timeout = listenerLifecycleTestHooks?.synchronousTimeout ?? .seconds(10)
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            // Cancel this caller's interest, never a newer listener or another waiter.
            cancel(request)
            task.cancel()
            throw HttpServerError.bindFailed("Server start timed out.")
        }
        if let error = box.error {
            throw error
        }
        guard finish(request) else { throw CancellationError() }
    }

    /// 启动服务(async)。
    /// - Parameters:
    ///   - port: 监听端口;0 表示交由系统分配
    ///   - forceIPv4: true 时强制 IPv4 bind;false 时允许双栈
    ///   - tls: 非 nil 时启用 HTTPS;由 TLSConfig 提供 server identity
    /// Concurrent starts share the active listener and its original options. Cancelling
    /// one pending caller leaves other callers intact. A restart waits for the previous
    /// listener's native cancellation before binding again, including on the same port.
    public func startAsync(_ port: in_port_t = 8080, forceIPv4: Bool = false, tls: TLSConfig? = nil) async throws {
        let request = StartRequest()
        do {
            try await startOperation(request, port: port, forceIPv4: forceIPv4, tls: tls)
            guard finish(request) else { throw CancellationError() }
        } catch {
            cancel(request)
            throw error
        }
    }

    private func startOperation(_ request: StartRequest, port: in_port_t,
                                forceIPv4: Bool, tls: TLSConfig?) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let epoch = lifecycleLock.withLock { stopEpoch }
            listenerLifecycleTestHooks?.beforeBegin?()
            begin(request, epoch: epoch, port: port, forceIPv4: forceIPv4, tls: tls)
            try await request.completion.wait()
            try Task.checkCancellation()
        } onCancel: {
            self.cancel(request)
        }
    }

    /// 同步停机 —— 取消 listener、关闭所有连接、复位状态。
    public func stop() {
        let shutdown = lifecycleLock.withLock { () -> Shutdown in
            stopEpoch &+= 1
            return detachAttempt()
        }
        shutdown.finish(CancellationError())
    }

    private func begin(_ request: StartRequest, epoch: UInt64, port: in_port_t,
                       forceIPv4: Bool, tls: TLSConfig?) {
        lifecycleLock.lock()
        guard !request.cancelled, !Task.isCancelled, stopEpoch == epoch else {
            pendingStarts[request.id] = nil
            lifecycleLock.unlock()
            request.completion.fulfill(.failure(CancellationError()))
            return
        }
        guard retiringListeners.isEmpty else {
            pendingStarts[request.id] = PendingStart(request: request, epoch: epoch,
                port: port, forceIPv4: forceIPv4, tls: tls)
            lifecycleLock.unlock()
            return
        }
        pendingStarts[request.id] = nil
        if let attempt {
            request.attempt = attempt
            attempt.requests[request.id] = request
            let ready = stateValue == HttpServerIOState.running.rawValue
            lifecycleLock.unlock()
            if ready { request.completion.fulfill(.success(())) }
            return
        }
        do {
            let params = Self.makeParameters(forceIPv4: forceIPv4, tls: tls)
            let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
            if connectionHandler != nil,
               let address = forceIPv4 ? listenAddressIPv4 : listenAddressIPv6 {
                params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: endpointPort)
            }
            let listener = try NWListener(using: params, on: endpointPort)
            let attempt = ListenerAttempt(listener: listener)
            self.attempt = attempt
            request.attempt = attempt
            attempt.requests[request.id] = request
            forceIPv4Active = forceIPv4
            stateValue = HttpServerIOState.starting.rawValue
            listener.newConnectionHandler = { [weak self, weak attempt] connection in
                guard let self, let attempt else { connection.cancel(); return }
                self.handleNewConnection(connection, attempt: attempt)
            }
            let attemptID = attempt.id
            listener.stateUpdateHandler = { [weak self, weak attempt] state in
                guard let self else { return }
                let hooks = self.listenerLifecycleTestHooks
                if case .cancelled = state {
                    if let beforeReceipt = hooks?.beforeCancellationReceipt {
                        DispatchQueue.global(qos: .userInitiated).async {
                            beforeReceipt(attemptID)
                            self.handleCancellationReceipt(attemptID)
                            hooks?.didCancelListener?(attemptID)
                        }
                    } else {
                        self.handleCancellationReceipt(attemptID)
                        hooks?.didCancelListener?(attemptID)
                    }
                    return
                }
                guard let attempt else { return }
                if case .ready = state, let beforeReady = hooks?.beforeReady {
                    // Fault injection delays our publication, never Network's cancellation queue.
                    DispatchQueue.global(qos: .userInitiated).async {
                        beforeReady(attempt.id)
                        self.handleListenerState(state, attempt: attempt)
                        hooks?.afterReady?(attempt.id)
                    }
                } else {
                    self.handleListenerState(state, attempt: attempt)
                }
            }
            listener.start(queue: attempt.queue)
            let didCreate = testHooks?.didCreateListener
            lifecycleLock.unlock()
            didCreate?(attempt.id, listener)
        } catch {
            let failure = Self.bindError(error, reportsAddressInUse: connectionHandler != nil)
            lifecycleLock.unlock()
            request.completion.fulfill(.failure(failure))
        }
    }

    private func cancel(_ request: StartRequest) {
        lifecycleLock.lock()
        request.cancelled = true
        pendingStarts[request.id] = nil
        var shutdown: Shutdown?
        if let owner = request.attempt, attempt === owner {
            owner.requests[request.id] = nil
            request.attempt = nil
            if owner.requests.isEmpty && !owner.hasDeliveredStarter {
                shutdown = detachAttempt()
            }
        }
        lifecycleLock.unlock()
        request.completion.fulfill(.failure(CancellationError()))
        shutdown?.finish(CancellationError())
    }

    /// A sync caller acknowledges only after receiving its semaphore signal.
    private func finish(_ request: StartRequest) -> Bool {
        lifecycleLock.withLock {
            guard !request.cancelled, let owner = request.attempt, attempt === owner,
                  stateValue == HttpServerIOState.running.rawValue else { return false }
            owner.hasDeliveredStarter = true
            owner.requests[request.id] = nil
            request.attempt = nil
            return true
        }
    }

    private func handleListenerState(_ state: NWListener.State, attempt owner: ListenerAttempt) {
        lifecycleLock.lock()
        guard attempt === owner else { lifecycleLock.unlock(); return }
        switch state {
        case .ready:
            guard stateValue == HttpServerIOState.starting.rawValue else {
                lifecycleLock.unlock()
                return
            }
            guard let port = owner.listener.port else {
                let shutdown = detachAttempt()
                lifecycleLock.unlock()
                shutdown.finish(HttpServerError.notRunning)
                return
            }
            resolvedPort = port.rawValue
            stateValue = HttpServerIOState.running.rawValue
            let requests = Array(owner.requests.values)
            lifecycleLock.unlock()
            for request in requests { request.completion.fulfill(.success(())) }
        case .waiting(let error), .failed(let error):
            let failure = Self.bindError(error, reportsAddressInUse: connectionHandler != nil)
            let shutdown = detachAttempt()
            lifecycleLock.unlock()
            shutdown.finish(failure)
        default:
            lifecycleLock.unlock()
        }
    }

    private func handleCancellationReceipt(_ id: UUID) {
        lifecycleLock.lock()
        let shutdown = attempt?.id == id ? detachAttempt(cancelListener: false) : nil
        retiringListeners[id] = nil
        let pending = retiringListeners.isEmpty ? Array(pendingStarts.values) : []
        // Keep each request discoverable by stop until begin moves it to an attempt.
        lifecycleLock.unlock()
        shutdown?.finish(CancellationError())
        for next in pending {
            begin(next.request, epoch: next.epoch, port: next.port,
                  forceIPv4: next.forceIPv4, tls: next.tls)
        }
    }

    /// Must be called with lifecycleLock held. NWListener.cancel does not wait for readiness.
    private func detachAttempt(cancelListener: Bool = true, closeConnections: Bool = true) -> Shutdown {
        let requests = (attempt.map { Array($0.requests.values) } ?? [])
            + pendingStarts.values.map(\.request)
        pendingStarts.removeAll()
        for request in requests {
            request.cancelled = true
            request.attempt = nil
        }
        attempt?.requests.removeAll()
        if cancelListener, let attempt {
            retiringListeners[attempt.id] = attempt.listener
            attempt.listener.cancel()
        }
        attempt = nil
        resolvedPort = nil
        stateValue = HttpServerIOState.stopped.rawValue
        let transports = closeConnections ? Array(connections.values) : []
        if closeConnections { connections.removeAll() }
        return Shutdown(requests: requests, transports: transports)
    }

    /// End listener admission while leaving the opt-in handler's accepted connections alive.
    public func stopAcceptingConnections() {
        let shutdown = lifecycleLock.withLock { () -> Shutdown in
            stopEpoch &+= 1
            return detachAttempt(closeConnections: connectionHandler == nil)
        }
        shutdown.finish(CancellationError())
    }

    private func isRunning(_ owner: ListenerAttempt) -> Bool {
        lifecycleLock.withLock { attempt === owner && stateValue == HttpServerIOState.running.rawValue }
    }

    /// 默认 dispatch:返回 404。子类 HttpServer 覆盖。
    open func dispatch(_ request: HttpRequest) -> ([String: String], HttpHandler) {
        return ([:], .sync { _ in HttpResponse.notFound(nil) })
    }

    // MARK: - Connection lifecycle

    private func handleNewConnection(_ conn: NWConnection, attempt owner: ListenerAttempt) {
        lifecycleLock.lock()
        guard attempt === owner, stateValue == HttpServerIOState.running.rawValue else {
            lifecycleLock.unlock()
            conn.cancel()
            return
        }
        let id = UUID()
        let transport = NWTransport(conn)
        connections[id] = transport
        let handler = connectionHandler

        // 每连接独立 queue —— 避免所有连接的 receive/send 回调串行化在共享 listenerQueue 上
        // 造成的并发吞吐瓶颈(listener 自身仍用 listenerQueue)
        let connQueue = DispatchQueue(label: "swifter.httpserverio.conn", qos: .userInitiated)
        conn.start(queue: connQueue)
        lifecycleLock.unlock()

        Task.detached { [weak self] in
            do {
                if let handler { await handler(transport) }
                else { try await self?.handleConnection(transport, attempt: owner) }
            } catch {
                // disconnected/EOF 是常态,无需打印
            }
            if let self {
                _ = self.lifecycleLock.withLock { self.connections.removeValue(forKey: id) }
                self.listenerLifecycleTestHooks?.didFinishConnection?(owner.id)
            }
            transport.close()
        }
    }

    private func handleConnection(_ transport: HttpTransport, attempt owner: ListenerAttempt) async throws {
        let parser = HttpParser()
        parser.maxRequestBodySize = maxRequestBodySize
        while isRunning(owner) {
            let request: HttpRequest
            do {
                request = try await parser.readHttpRequest(transport)
            } catch HttpParserError.requestBodyTooLarge {
                // 声明的 Content-Length 超限 —— 不读 body,回 413 后关连接,避免 OOM
                let resp = HttpResponse.raw(413, "Payload Too Large", nil) {
                    try $0.write([UInt8]("Request body too large.".utf8))
                }
                if isRunning(owner) { _ = try? await respond(transport, response: resp, keepAlive: false) }
                return
            } catch {
                // 客户端断开 / 报文异常,结束该连接
                return
            }
            listenerLifecycleTestHooks?.beforeRequestDispatch?(owner.id, request.path)
            guard isRunning(owner) else { return }
            request.address = transport.peername
            let (params, handler) = self.dispatch(request)
            request.params = params

            let response: HttpResponse
            do {
                switch handler {
                case .sync(let block):
                    response = block(request)
                case .async(let block):
                    response = try await block(request)
                }
            } catch {
                response = .internalServerError(.text("\(error)"))
            }

            var keepConnection = parser.supportsKeepAlive(request.headers)
            do {
                if isRunning(owner) {
                    keepConnection = try await respond(transport, response: response, keepAlive: keepConnection)
                }
            } catch {
                print("Failed to send response: \(error)")
            }

            if let session = response.transportSession(), isRunning(owner) {
                delegate?.transportConnectionReceived(transport)
                await session(transport)
                return
            }
            if !keepConnection { return }
        }
    }

    // MARK: - Response writing

    /// 把 non-Sendable 值(如 content.write 闭包)安全带过 DispatchQueue 边界。
    /// 我方保证:被包裹的闭包只在派发的 block 内调用一次,且其捕获的是不可变响应数据。
    private final class UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// 流式响应体写出器:把 sync 的 HttpResponseBodyWriter 调用逐块桥到 async transport。
    /// 关键约束:本类型的 write 方法只能在 respond 派发的 libdispatch 全局 queue 线程上调用
    /// (非 Swift 协作线程池),因为 writeBlocking 会同步阻塞当前线程等待该块送达协议栈。
    private struct InnerWriteContext: HttpResponseBodyWriter {

        let transport: HttpTransport

        /// 单块上限 —— 常驻内存与响应体大小无关
        private static let chunkSize = 64 * 1024

        /// 阻塞写一块:在当前(dispatch)线程等待 transport.write 完成再返回。
        /// transport.write 自身 await NWConnection 的 .contentProcessed,
        /// 因此天然提供背压;此处只是把它从 sync 上下文驱动。内层 Task 跑在协作池
        /// (此刻空闲 —— respond 已在 withCheckedContinuation 处挂起让出),不会死锁。
        private func writeBlocking(_ chunk: ArraySlice<UInt8>) throws {
            let sem = DispatchSemaphore(value: 0)
            let box = ErrorBox()
            Task {
                do { try await transport.write(chunk) }
                catch { box.error = error }
                sem.signal()
            }
            sem.wait()
            if let error = box.error { throw error }
        }

        func write(_ file: String.File) throws {
            // 逐 64KB 读盘、逐块流式写出 —— 从不把整文件读进内存(还原上游 sendfile 语义)
            var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
            while true {
                let count = try file.read(&chunk)
                if count <= 0 { break }
                try writeBlocking(ArraySlice(chunk[0..<count]))
                if count < chunk.count { break }
            }
            file.close()
        }

        func write(_ data: [UInt8]) throws {
            try writeChunked(ArraySlice(data))
        }

        func write(_ data: ArraySlice<UInt8>) throws {
            try writeChunked(data)
        }

        func write(_ data: NSData) throws {
            try write(Data(referencing: data))
        }

        func write(_ data: Data) throws {
            try writeChunked(ArraySlice([UInt8](data)))
        }

        /// 把任意大小的内存 body 切成 ≤chunkSize 块逐块阻塞写,避免单次 Data(600MB) 之类的巨分配
        private func writeChunked(_ data: ArraySlice<UInt8>) throws {
            var idx = data.startIndex
            while idx < data.endIndex {
                let end = Swift.min(idx + Self.chunkSize, data.endIndex)
                try writeBlocking(data[idx..<end])
                idx = end
            }
        }
    }

    private func respond(_ transport: HttpTransport, response: HttpResponse, keepAlive: Bool) async throws -> Bool {
        guard self.operating else { return false }

        var responseHeader = String()
        responseHeader.append("HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n")

        let content = response.content()

        if content.length >= 0 {
            responseHeader.append("Content-Length: \(content.length)\r\n")
        }

        if keepAlive && content.length != -1 {
            responseHeader.append("Connection: keep-alive\r\n")
        }

        for (name, value) in response.headers() {
            // 多值 header（典型 Set-Cookie，也含其它 array-valued header）：上层用 `\n`
            // 连成多行 sentinel（`\n` 在 HTTP header 值里非法，故无歧义），这里按 `\n`
            // 拆成多个独立 header 行——对齐标准/Node 的多 Set-Cookie 语义（逗号合并对
            // Set-Cookie 非法）。无 `\n` 的普通值 components 返回单元素、行为不变。
            for line in value.components(separatedBy: "\n") {
                responseHeader.append("\(name): \(line)\r\n")
            }
        }

        responseHeader.append("\r\n")

        // Some web-socket clients (Jetfire) want the header in a single packet —
        // header 先 await 写出,在 body 之前;NWConnection.send FIFO 保证顺序
        try await transport.write(responseHeader)

        if let writeClosure = content.write {
            // HttpResponseBodyWriter 是 sync 协议,transport.write 是 async。
            // 把 writeClosure 派发到 libdispatch 全局 queue(离开 Swift 协作线程池),
            // 内部逐块阻塞写(InnerWriteContext)。这样:
            //   - 响应体逐块流式写出,常驻内存 ≤ 64KB(不再全量缓冲 + 二次拷贝)
            //   - transport.write 自身 await .contentProcessed,提供原生背压
            //   - 阻塞发生在 dispatch 线程,不污染协作池(不会饥饿/死锁)
            //   - 最后一块写完(continuation resume)才返回,保证 flush-before-close
            let boxed = UncheckedSendableBox(writeClosure)
            let context = InnerWriteContext(transport: transport)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try boxed.value(context)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }

        return keepAlive && content.length != -1
    }

    // MARK: - NWParameters factory

    private static func bindError(_ error: Error, reportsAddressInUse: Bool) -> HttpServerError {
        if reportsAddressInUse, let error = error as? NWError, case .posix(.EADDRINUSE) = error { return .addressInUse }
        return .bindFailed(error.localizedDescription)
    }

    private static func makeParameters(forceIPv4: Bool, tls: TLSConfig?) -> NWParameters {
        let params: NWParameters
        if let tls = tls {
            params = NWParameters(tls: tls.tlsOptions, tcp: .init())
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        if forceIPv4 {
            // 强制 IPv4:禁用 IPv6 协议栈
            if let ipOption = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOption.version = .v4
            }
        }
        return params
    }
}

public enum HttpServerError: Error, Sendable {
    case bindFailed(String)
    case addressInUse
    case notRunning
}

/// sync wrapper 用的 boxed error
private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

// MARK: - Listener-ready async helper

private final class ListenerReadyAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func fulfill(_ r: Result<Void, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        switch r {
        case .success: waiter?.resume()
        case .failure(let error): waiter?.resume(throwing: error)
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result = result {
                lock.unlock()
                switch result {
                case .success: cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            } else {
                waiter = cont
                lock.unlock()
            }
        }
    }
}
