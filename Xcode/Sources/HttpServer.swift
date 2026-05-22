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

    override open func dispatch(_ request: HttpRequest) -> ([String: String], HttpHandler) {
        for layer in middleware {
            if let response = layer(request) {
                return ([:], .sync { _ in response })
            }
        }
        if let result = router.route(request.method, path: request.path) {
            return result
        }
        if let asyncNotFound = self.notFoundAsyncHandler {
            return ([:], .async(asyncNotFound))
        }
        if let notFoundHandler = self.notFoundHandler {
            return ([:], .sync(notFoundHandler))
        }
        return super.dispatch(request)
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
