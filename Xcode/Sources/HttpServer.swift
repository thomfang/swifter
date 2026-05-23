//
//  HttpServer.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation

open class HttpServer: HttpServerIO {

    public static let VERSION: String = {
        let bundle = Bundle(for: HttpServer.self)
        guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else { return "Unspecified" }
        return version
    }()

    private let router = HttpRouter()

    public override init() {
        self.DELETE = MethodRoute(method: "DELETE", router: router)
        self.PATCH  = MethodRoute(method: "PATCH", router: router)
        self.HEAD   = MethodRoute(method: "HEAD", router: router)
        self.POST   = MethodRoute(method: "POST", router: router)
        self.GET    = MethodRoute(method: "GET", router: router)
        self.PUT    = MethodRoute(method: "PUT", router: router)

        self.delete = MethodRoute(method: "DELETE", router: router)
        self.patch  = MethodRoute(method: "PATCH", router: router)
        self.head   = MethodRoute(method: "HEAD", router: router)
        self.post   = MethodRoute(method: "POST", router: router)
        self.get    = MethodRoute(method: "GET", router: router)
        self.put    = MethodRoute(method: "PUT", router: router)
    }

    public var DELETE, PATCH, HEAD, POST, GET, PUT: MethodRoute
    public var delete, patch, head, post, get, put: MethodRoute

    /// 兼容旧 API:sync handler 通过 subscript 注册
    public subscript(path: String) -> (@Sendable (HttpRequest) -> HttpResponse)? {
        get { return nil }
        set {
            router.register(nil, path: path, handler: newValue)
        }
    }

    /// 注册 async handler(任意 method)
    public func setAsync(_ path: String, handler: @escaping @Sendable (HttpRequest) async throws -> HttpResponse) {
        router.register(nil, path: path, asyncHandler: handler)
    }

    public var routes: [String] {
        return router.routes()
    }

    /// 兼容旧 API:sync notFound
    public var notFoundHandler: (@Sendable (HttpRequest) -> HttpResponse)?

    /// 新接口:async notFound;若设置,优先于 notFoundHandler
    public var notFoundAsyncHandler: (@Sendable (HttpRequest) async throws -> HttpResponse)?

    public var middleware = [@Sendable (HttpRequest) -> HttpResponse?]()

    /// async middleware 链。每层可以返回 nil 表示放行,或返回 HttpResponse
    /// 截胡(后续 middleware 和 route handler 都不执行)。
    /// dispatch 会把整条链 + 路由 handler 包成一个 .async handler 交给 IO 层 await。
    public var asyncMiddleware = [@Sendable (HttpRequest) async throws -> HttpResponse?]()

    /// 便捷注册:append 一层 async middleware
    public func use(_ middleware: @escaping @Sendable (HttpRequest) async throws -> HttpResponse?) {
        asyncMiddleware.append(middleware)
    }

    override open func dispatch(_ request: HttpRequest) -> ([String: String], HttpHandler) {
        // 1) sync middleware 链:任一层命中直接同步返回(向后兼容上游)
        for layer in middleware {
            if let response = layer(request) {
                return ([:], .sync { _ in response })
            }
        }

        // 2) 路由 + 兜底
        let routed: ([String: String], HttpHandler)
        if let result = router.route(request.method, path: request.path) {
            routed = result
        } else if let asyncNotFound = self.notFoundAsyncHandler {
            routed = ([:], .async(asyncNotFound))
        } else if let notFoundHandler = self.notFoundHandler {
            routed = ([:], .sync(notFoundHandler))
        } else {
            return super.dispatch(request)
        }

        // 3) 如果挂了 async middleware,就把 routed handler 包一层:
        //    依次 await 每个 middleware,有命中直接返回,否则继续走原 handler。
        //    注意捕获 asyncMiddleware 当前快照,避免分发期间被并发修改影响行为
        guard !asyncMiddleware.isEmpty else { return routed }

        let chain = asyncMiddleware
        let inner = routed.1
        let wrapped: HttpHandler = .async { req in
            for layer in chain {
                if let response = try await layer(req) {
                    return response
                }
            }
            switch inner {
            case .sync(let block):  return block(req)
            case .async(let block): return try await block(req)
            }
        }
        return (routed.0, wrapped)
    }

    public struct MethodRoute {
        public let method: String
        public let router: HttpRouter

        /// 兼容旧 API:sync handler 通过 method subscript 注册
        public subscript(path: String) -> (@Sendable (HttpRequest) -> HttpResponse)? {
            get { return nil }
            set {
                router.register(method, path: path, handler: newValue)
            }
        }

        /// 注册 method 限定的 async handler
        public func setAsync(_ path: String, handler: @escaping @Sendable (HttpRequest) async throws -> HttpResponse) {
            router.register(method, path: path, asyncHandler: handler)
        }
    }
}
