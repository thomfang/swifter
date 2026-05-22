//
//  HttpHandlers+Files.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//

import Foundation

public func shareFile(_ path: String) -> ((HttpRequest) -> HttpResponse) {
    return { _ in
        // fopen 在目录上不会失败 —— 它返回非 nil 但 fread 拿到空数据,会让客户端
        // 看到 200 + 空 body。在打开前显式排除目录,改返回 404
        if (try? path.directory()) == true {
            return .notFound()
        }
        if let file = try? path.openForReading() {
            let mimeType = path.mimeType()
            var responseHeader: [String: String] = ["Content-Type": mimeType]

            if let attr = try? FileManager.default.attributesOfItem(atPath: path),
                let fileSize = attr[FileAttributeKey.size] as? UInt64 {
                responseHeader["Content-Length"] = String(fileSize)
            }
            return .raw(200, "OK", responseHeader, { writer in
                try? writer.write(file)
                file.close()
            })
        }
        return .notFound()
    }
}

public func shareFilesFromDirectory(_ directoryPath: String, defaults: [String] = ["index.html", "default.html"]) -> ((HttpRequest) -> HttpResponse) {
    return { request in
        guard let fileRelativePath = request.params.first else {
            return .notFound()
        }
        if fileRelativePath.value.isEmpty {
            for path in defaults {
                let candidate = directoryPath + String.pathSeparator + path
                if (try? candidate.directory()) == true { continue }
                if let file = try? candidate.openForReading() {
                    let mimeType = candidate.mimeType()
                    var responseHeader: [String: String] = ["Content-Type": mimeType]
                    if let attr = try? FileManager.default.attributesOfItem(atPath: candidate),
                       let fileSize = attr[FileAttributeKey.size] as? UInt64 {
                        responseHeader["Content-Length"] = String(fileSize)
                    }
                    return .raw(200, "OK", responseHeader, { writer in
                        try? writer.write(file)
                        file.close()
                    })
                }
            }
            return .notFound()
        }
        let filePath = directoryPath + String.pathSeparator + fileRelativePath.value

        // 命中目录时 fopen 不会失败但 fread 拿不到内容;显式 404 比 200 + 空 body
        // 对调用方更友好
        if (try? filePath.directory()) == true {
            return .notFound()
        }

        if let file = try? filePath.openForReading() {
            let mimeType = fileRelativePath.value.mimeType()
            var responseHeader: [String: String] = ["Content-Type": mimeType]

            if let attr = try? FileManager.default.attributesOfItem(atPath: filePath),
                let fileSize = attr[FileAttributeKey.size] as? UInt64 {
                responseHeader["Content-Length"] = String(fileSize)
            }

            return .raw(200, "OK", responseHeader, { writer in
                try? writer.write(file)
                file.close()
            })
        }
        return .notFound()
    }
}

public func directoryBrowser(_ dir: String) -> ((HttpRequest) -> HttpResponse) {
    return { request in
        guard let (_, value) = request.params.first else {
            return .notFound()
        }
        let filePath = dir + String.pathSeparator + value
        do {
            guard try filePath.exists() else {
                return .notFound()
            }
            if try filePath.directory() {
                var files = try filePath.files()
                files.sort(by: {$0.lowercased() < $1.lowercased()})
                return scopes {
                    html {
                        body {
                            table(files) { file in
                                tr {
                                    td {
                                        a {
                                            href = request.path + "/" + file
                                            inner = file
                                        }
                                    }
                                }
                            }
                        }
                    }
                    }(request)
            } else {
                guard let file = try? filePath.openForReading() else {
                    return .notFound()
                }
                return .raw(200, "OK", [:], { writer in
                    try? writer.write(file)
                    file.close()
                })
            }
        } catch {
            return HttpResponse.internalServerError(.text("Internal Server Error"))
        }
    }
}
