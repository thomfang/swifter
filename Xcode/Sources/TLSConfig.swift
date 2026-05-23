//
//  TLSConfig.swift
//  Swifter
//
//  HTTPS 服务端 TLS 配置。
//
//  支持的 identity 来源:
//    - P12 文件路径 (TLSConfig.p12(path:password:))
//    - P12 字节流  (TLSConfig.p12(data:password:))
//
//  支持的协议版本控制:
//    - minVersion / maxVersion 可以钉死单一版本(只允许 TLSv1.3)
//      或允许一段范围(min TLSv1.2, max TLSv1.3)。默认 min=TLSv1.2,max 不限。
//

import Foundation
import Network
import Security

public enum TLSConfigError: Error, Sendable {
    /// P12 文件路径不存在或不可读
    case p12FileNotFound(String)
    /// P12 字节流为空
    case p12DataEmpty
    /// SecPKCS12Import 解析失败(密码错或文件损坏)。OSStatus 不携带密码内容。
    case p12ImportFailed(OSStatus)
    /// P12 导入成功但未找到 identity
    case identityNotFound
    /// SecIdentity 转 sec_identity_t 失败
    case secIdentityConversionFailed
}

/// TLS 协议版本枚举,直接映射到 Network 框架的 tls_protocol_version_t。
/// 抽出来是为了让上层(JS / 调用方)不用直接接触 Network 私有类型。
/// 只暴露 1.2 / 1.3 —— Apple 在 macOS 12 / iOS 15 之后弃用了 TLSv1.0/1.1,
/// 现代服务端不应该再支持这两个版本。
public enum TLSVersion: String, Sendable, CaseIterable {
    case v1_2 = "1.2"
    case v1_3 = "1.3"

    var nwValue: tls_protocol_version_t {
        switch self {
        case .v1_2: return .TLSv12
        case .v1_3: return .TLSv13
        }
    }

    /// 解析 "1.2" / "TLSv1.2" / "TLS1.2" 形式的字符串,大小写不敏感。
    /// 解析失败返回 nil,调用方决定走默认还是报错。
    public static func parse(_ raw: String) -> TLSVersion? {
        let normalized = raw.lowercased()
            .replacingOccurrences(of: "tlsv", with: "")
            .replacingOccurrences(of: "tls", with: "")
            .trimmingCharacters(in: .whitespaces)
        return TLSVersion(rawValue: normalized)
    }
}

/// 用于 HttpServerIO.start(tls:) 的不可变 TLS 配置。
public struct TLSConfig: Sendable {

    /// 直接交给 NWParameters(tls:) 的 Options。框架持有不变;TLSConfig 复制时
    /// 内部 NWProtocolTLS.Options 是 reference,但 NWParameters 自身会按需 copy。
    let tlsOptions: NWProtocolTLS.Options

    private init(tlsOptions: NWProtocolTLS.Options) {
        self.tlsOptions = tlsOptions
    }

    /// 从 P12 文件加载 server identity。
    /// - Parameters:
    ///   - path: 绝对路径或可被 FileManager 读取的相对路径
    ///   - password: P12 文件密码
    ///   - minVersion: 最低 TLS 协议版本,默认 1.2
    ///   - maxVersion: 最高 TLS 协议版本,默认 nil(不限,跟随系统支持的最高版本)
    /// - Throws: TLSConfigError 当文件不存在/密码错/identity 缺失时
    public static func p12(
        path: String,
        password: String,
        minVersion: TLSVersion = .v1_2,
        maxVersion: TLSVersion? = nil
    ) throws -> TLSConfig {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TLSConfigError.p12FileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        return try p12(data: data, password: password, minVersion: minVersion, maxVersion: maxVersion)
    }

    /// 从 P12 字节流加载 server identity。
    /// JS 侧把 keychain 取出来的 P12 二进制直接传过来用这个入口。
    /// - Parameters:
    ///   - data: P12 二进制字节(可以是 keychain 读出的 Data,base64 解码后的 Data 等)
    ///   - password: P12 密码
    ///   - minVersion: 最低 TLS 协议版本,默认 1.2
    ///   - maxVersion: 最高 TLS 协议版本,默认 nil(不限)
    /// - Throws: TLSConfigError
    public static func p12(
        data: Data,
        password: String,
        minVersion: TLSVersion = .v1_2,
        maxVersion: TLSVersion? = nil
    ) throws -> TLSConfig {
        guard !data.isEmpty else {
            throw TLSConfigError.p12DataEmpty
        }

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess else {
            throw TLSConfigError.p12ImportFailed(status)
        }
        guard let items = rawItems as? [[String: Any]], let first = items.first else {
            throw TLSConfigError.identityNotFound
        }
        guard let identityCF = first[kSecImportItemIdentity as String] else {
            throw TLSConfigError.identityNotFound
        }
        // kSecImportItemIdentity 实际是 SecIdentityRef,直接 cast
        let secIdentity = identityCF as! SecIdentity

        guard let secIdentityRef = sec_identity_create(secIdentity) else {
            throw TLSConfigError.secIdentityConversionFailed
        }

        let opts = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(opts.securityProtocolOptions, secIdentityRef)
        sec_protocol_options_set_min_tls_protocol_version(opts.securityProtocolOptions, minVersion.nwValue)
        if let maxVersion {
            sec_protocol_options_set_max_tls_protocol_version(opts.securityProtocolOptions, maxVersion.nwValue)
        }

        return TLSConfig(tlsOptions: opts)
    }
}
