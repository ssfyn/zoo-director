import Foundation
import Security

/// 直接保存上传密码或修复条目元数据，避开上传工具保存引用字符串的问题。
enum AppStoreKeychain {
    /// 构造限定到已知标签和账号的查询，不遍历或读取其他凭据。
    static func query(item: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrLabel as String: item,
         kSecAttrAccount as String: account]
    }

    /// 只读取唯一条目的公开元数据，缺失时返回空值。
    static func attributes(item: String, account: String) throws -> [String: Any]? {
        let query = query(item: item, account: account)
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let records = result as? [[String: Any]], records.count == 1 else {
            throw failure("无法唯一定位上传条目", status: status)
        }
        return records[0]
    }

    /// 仅补齐缺失服务名，不读取或改动条目的密码和访问控制权限。
    static func repair(item: String, account: String) throws {
        guard let record = try attributes(item: item, account: account) else {
            throw failure("找不到上传条目", status: errSecItemNotFound)
        }
        let service = record[kSecAttrService as String] as? String ?? ""
        if service == item { return }
        guard service.isEmpty else { throw failure("条目已有其他服务名，未修改", status: errSecParam) }
        let updated = SecItemUpdate(query(item: item, account: account) as CFDictionary,
                                    [kSecAttrService as String: item] as CFDictionary)
        guard updated == errSecSuccess else { throw failure("无法补齐上传条目的服务名", status: updated) }
        print("已补齐上传钥匙串条目的服务名称，密码内容未读取或改动。")
    }

    /// 从隐藏输入所传的进程环境保存真实密码，不把值放入命令参数或输出。
    static func store(item: String, account: String) throws {
        guard let password = ProcessInfo.processInfo.environment["ZOODIRECTOR_APPSTORE_PASSWORD"],
              !password.isEmpty, !password.hasPrefix("@env:"), !password.hasPrefix("@keychain:") else {
            throw failure("请输入实际 App 专用密码", status: errSecParam)
        }
        let value: [String: Any] = [kSecValueData as String: Data(password.utf8), kSecAttrService as String: item]
        let status: OSStatus
        if let record = try attributes(item: item, account: account) {
            let service = record[kSecAttrService as String] as? String ?? ""
            guard service.isEmpty || service == item else {
                throw failure("已有条目的服务名不同，未修改", status: errSecParam)
            }
            status = SecItemUpdate(query(item: item, account: account) as CFDictionary, value as CFDictionary)
        } else {
            var entry = query(item: item, account: account).merging(value) { _, new in new }
            entry[kSecAttrAccess as String] = try accessForAltool()
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure("无法保存上传密码", status: status) }
    }

    /// 新条目仅信任当前 Xcode 的上传工具；更新条目时保留原来的访问控制。
    static func accessForAltool() throws -> SecAccess {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "altool"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty else { throw failure("找不到上传工具", status: errSecParam) }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let engine = resolved.deletingLastPathComponent().appendingPathComponent("altool")
        var paths = [resolved.path]
        // 新版工具入口是启动器，实际读取条目的二进制位于同一目录。
        if engine.path != resolved.path, FileManager.default.isExecutableFile(atPath: engine.path) {
            paths.append(engine.path)
        }
        var applications: [SecTrustedApplication] = []
        for executable in paths {
            var trusted: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(executable, &trusted)
            guard status == errSecSuccess, let trusted else { throw failure("无法识别上传工具", status: status) }
            applications.append(trusted)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate("ZooDirector App Store upload" as CFString, applications as CFArray, &access)
        guard accessStatus == errSecSuccess, let access else { throw failure("无法配置上传工具访问", status: accessStatus) }
        return access
    }

    /// 只输出固定说明和状态码，避免异常中包含任何凭据内容。
    static func failure(_ message: String, status: OSStatus) -> NSError {
        NSError(domain: "ZooDirector.AppStoreKeychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(message)（\(status)）。"])
    }
}

guard CommandLine.arguments.count == 4, ["--store", "--repair"].contains(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("用法：swift appstore-keychain.swift --store|--repair 条目名称 账号\n".utf8))
    exit(1)
}
do {
    if CommandLine.arguments[1] == "--store" {
        try AppStoreKeychain.store(item: CommandLine.arguments[2], account: CommandLine.arguments[3])
    } else {
        try AppStoreKeychain.repair(item: CommandLine.arguments[2], account: CommandLine.arguments[3])
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
