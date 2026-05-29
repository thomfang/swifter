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

    // NSLock 保护状态读写 —— 取代已废弃且不检查返回值(转换可被静默丢弃)的
    // OSAtomicCompareAndSwapInt。start/stop 与连接 task 会并发读 state。
    private let stateLock = NSLock()
    private var stateValue: Int32 = HttpServerIOState.stopped.rawValue

    public private(set) var state: HttpServerIOState {
        get {
            stateLock.lock(); defer { stateLock.unlock() }
            return HttpServerIOState(rawValue: stateValue)!
        }
        set {
            stateLock.lock(); stateValue = newValue.rawValue; stateLock.unlock()
        }
    }

    public var operating: Bool { return self.state == .running }

    /// String representation of the IPv4 address to receive requests from.
    /// 当 forceIPv4 = true 时使用;否则用 listenAddressIPv6。
    public var listenAddressIPv4: String?

    /// String representation of the IPv6 address to receive requests from.
    public var listenAddressIPv6: String?

    /// 在用的 NWListener;state 切到 running 后非 nil
    private var listener: NWListener?

    /// 当前活跃的 transport 集合,stop() 时统一关掉
    private let connectionsLock = NSLock()
    private var connections: [UUID: HttpTransport] = [:]

    /// listener 的 dispatch queue
    private let listenerQueue = DispatchQueue(label: "swifter.httpserverio.listener", qos: .userInitiated)

    /// listener 启动后报告的本地端口 —— start 完成时已经 ready,有值
    private var resolvedPort: UInt16?

    public init() {}

    deinit {
        stop()
    }

    public func port() throws -> Int {
        guard let resolvedPort = resolvedPort else {
            throw HttpServerError.notRunning
        }
        return Int(resolvedPort)
    }

    public func isIPv4() throws -> Bool {
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
        // sync 调用方可能在 main thread (UserInteractive QoS) 等 semaphore;
        // Task.detached 默认走 .medium,会触发 priority inversion 告警。
        // 把 Task 提升到 .userInitiated,与 sync caller 的优先级匹配。
        Task.detached(priority: .userInitiated) { [box, self] in
            do {
                try await self.startAsync(port, forceIPv4: forceIPv4, tls: tls)
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        // 加超时兜底:startAsync 会在 .ready/.failed/.waiting 都 fulfill,正常应立即返回;
        // 此处防御未知挂起,避免 JS 主线程调 start() 时永久阻塞 → watchdog 崩。
        if semaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
            self.stop()
            throw HttpServerError.bindFailed("Server start timed out.")
        }
        if let error = box.error {
            throw error
        }
    }

    /// 启动服务(async)。
    /// - Parameters:
    ///   - port: 监听端口;0 表示交由系统分配
    ///   - forceIPv4: true 时强制 IPv4 bind;false 时允许双栈
    ///   - tls: 非 nil 时启用 HTTPS;由 TLSConfig 提供 server identity
    public func startAsync(_ port: in_port_t = 8080, forceIPv4: Bool = false, tls: TLSConfig? = nil) async throws {
        guard !self.operating else { return }
        stop()
        self.state = .starting
        self.forceIPv4Active = forceIPv4

        let params = HttpServerIO.makeParameters(forceIPv4: forceIPv4, tls: tls)
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: endpointPort)
        } catch {
            self.state = .stopped
            throw HttpServerError.bindFailed(error.localizedDescription)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }

        let ready = ListenerReadyAwaiter()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let resolved = listener.port?.rawValue
                self?.resolvedPort = resolved
                ready.fulfill(.success(()))
            case .failed(let error):
                self?.state = .stopped
                ready.fulfill(.failure(HttpServerError.bindFailed(error.localizedDescription)))
            case .waiting(let error):
                // 端口被占用 / 暂时无法监听。本机 server 不做无限重试 —— 直接报错,
                // 避免 ready.wait() 永不兑现导致 sync start() 永久阻塞调用线程。
                self?.state = .stopped
                ready.fulfill(.failure(HttpServerError.bindFailed(error.localizedDescription)))
            case .cancelled:
                self?.state = .stopped
            default:
                break
            }
        }

        listener.start(queue: listenerQueue)

        do {
            try await ready.wait()
        } catch {
            listener.cancel()
            self.listener = nil
            self.state = .stopped
            throw error
        }
        self.state = .running
    }

    /// 同步停机 —— 取消 listener、关闭所有连接、复位状态。
    public func stop() {
        guard self.operating || self.state == .starting else { return }
        self.state = .stopping

        // 关掉所有活跃 transport(keep-alive / websocket 循环会感知 disconnected 退出)
        connectionsLock.lock()
        let snapshot = Array(connections.values)
        connections.removeAll(keepingCapacity: true)
        connectionsLock.unlock()
        for transport in snapshot {
            transport.close()
        }

        listener?.cancel()
        listener = nil
        resolvedPort = nil

        self.state = .stopped
    }

    /// 默认 dispatch:返回 404。子类 HttpServer 覆盖。
    open func dispatch(_ request: HttpRequest) -> ([String: String], HttpHandler) {
        return ([:], .sync { _ in HttpResponse.notFound(nil) })
    }

    // MARK: - Connection lifecycle

    private func handleNewConnection(_ conn: NWConnection) {
        let id = UUID()
        let transport = NWTransport(conn)

        connectionsLock.lock()
        connections[id] = transport
        connectionsLock.unlock()

        // 每连接独立 queue —— 避免所有连接的 receive/send 回调串行化在共享 listenerQueue 上
        // 造成的并发吞吐瓶颈(listener 自身仍用 listenerQueue)
        let connQueue = DispatchQueue(label: "swifter.httpserverio.conn", qos: .userInitiated)
        conn.start(queue: connQueue)

        Task.detached { [weak self] in
            do {
                try await self?.handleConnection(transport)
            } catch {
                // disconnected/EOF 是常态,无需打印
            }
            self?.connectionsLock.lock()
            self?.connections.removeValue(forKey: id)
            self?.connectionsLock.unlock()
            transport.close()
        }
    }

    private func handleConnection(_ transport: HttpTransport) async throws {
        let parser = HttpParser()
        while self.operating {
            let request: HttpRequest
            do {
                request = try await parser.readHttpRequest(transport)
            } catch HttpParserError.requestBodyTooLarge {
                // 声明的 Content-Length 超限 —— 不读 body,回 413 后关连接,避免 OOM
                let resp = HttpResponse.raw(413, "Payload Too Large", nil) {
                    try $0.write([UInt8]("Request body too large.".utf8))
                }
                _ = try? await respond(transport, response: resp, keepAlive: false)
                return
            } catch {
                // 客户端断开 / 报文异常,结束该连接
                return
            }
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
                if self.operating {
                    keepConnection = try await respond(transport, response: response, keepAlive: keepConnection)
                }
            } catch {
                print("Failed to send response: \(error)")
            }

            if let session = response.transportSession() {
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
            responseHeader.append("\(name): \(value)\r\n")
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
        if let waiter = waiter {
            self.waiter = nil
            lock.unlock()
            switch r {
            case .success: waiter.resume()
            case .failure(let e): waiter.resume(throwing: e)
            }
        } else if result == nil {
            result = r
            lock.unlock()
        } else {
            lock.unlock()
        }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result = result {
                self.result = nil
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
