//
//  TLSConfig.swift
//  Swifter
//
//  HTTPS 服务端 TLS 配置 —— 当前仅支持 P12(PKCS#12)+ 密码加载形态。
//  其他形态(Keychain identity / PEM 证书 + 私钥分件)未来再加。
//

import Foundation
import Network
import Security

public enum TLSConfigError: Error, Sendable {
    /// P12 文件路径不存在或不可读
    case p12FileNotFound(String)
    /// SecPKCS12Import 解析失败(密码错或文件损坏)。OSStatus 不携带密码内容。
    case p12ImportFailed(OSStatus)
    /// P12 导入成功但未找到 identity
    case identityNotFound
    /// SecIdentity 转 sec_identity_t 失败
    case secIdentityConversionFailed
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
    /// - Throws: TLSConfigError 当文件不存在/密码错/identity 缺失时
    public static func p12(path: String, password: String) throws -> TLSConfig {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TLSConfigError.p12FileNotFound(path)
        }
        let data = try Data(contentsOf: url)

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
        // 默认 TLS 1.2 起步;主流客户端都支持
        sec_protocol_options_set_min_tls_protocol_version(opts.securityProtocolOptions, .TLSv12)

        return TLSConfig(tlsOptions: opts)
    }
}
