import Foundation
import Security

/// 可持久化的认证元信息，只记录用户名和钥匙串引用，不包含密码。
struct DigestConfiguration: Codable, Hashable, Sendable {
    /// 参与 digest 身份计算的原始用户名。
    var username: String
    /// 密码在钥匙串中的随机标识，更新密码时创建新引用。
    var credentialID = UUID()

    /// 用户名不能为空或含有协议分隔符，密码原文不裁剪。
    func validate() throws {
        guard !username.isEmpty, !username.contains(":"), !username.contains("\0") else {
            throw ZooKeeperError.message("The digest username cannot be empty or contain a colon or null character.")
        }
    }
}

/// 可替换的密码存储，测试使用内存实现，正式应用使用系统钥匙串。
protocol DigestPasswordStore: Sendable {
    /// 读取密码，缺失时返回空值，空字符串仍是有效密码。
    func load(_ id: UUID) throws -> String?
    /// 保存新引用的密码，不写入连接配置或日志。
    func save(_ password: String, id: UUID) throws
    /// 删除指定连接不再使用的密码，缺失视为成功。
    func remove(_ id: UUID) throws
}

/// 使用登录钥匙串保存应用独占的通用密码。
struct KeychainDigestPasswordStore: DigestPasswordStore {
    /// 固定服务名与应用标识一致，不与其他类型的密码共享条目。
    private let service = "fan.yanan.zoodirector.digest"

    /// 构建仅匹配本应用和随机凭据标识的查询。
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    /// 获取原始 UTF-8 密码，不将安全框架错误转换成密码正文。
    func load(_ id: UUID) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data, let password = String(data: data, encoding: .utf8) else {
            throw ZooKeeperError.message("The digest password in Keychain cannot be read. Enter it again.")
        }
        return password
    }

    /// 为随机新引用创建密码条目，避免先覆盖旧配置正在使用的密码。
    func save(_ password: String, id: UUID) throws {
        var request = query(id)
        request[kSecValueData as String] = Data(password.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        try check(SecItemAdd(request as CFDictionary, nil))
    }

    /// 仅移除本应用明确指定的条目，不遍历用户钥匙串。
    func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    /// 对用户报告固定错误及系统状态码，避免错误中包含用户名或密码。
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ZooKeeperError.message("Cannot access the digest password in Keychain (\(status)). Check system permissions.")
        }
    }
}
