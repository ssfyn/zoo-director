import Foundation

/// 应用独立保存服务器身份，不读写用户的系统主机信任记录。
enum SSHKnownHosts {
    /// 获取沙箱容器中的主机记录路径，目录在首次连接时创建。
    static func location() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("ZooDirector/SSH/known_hosts")
    }

    /// 用户明确确认后只移除指定服务器的旧公钥，兼容散列主机记录。
    static func forget(_ configuration: SSHConfiguration, file: URL? = nil) throws {
        try configuration.validateServer()
        let url = try file ?? location()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let host = configuration.port == 22 ? configuration.host : "[\(configuration.host)]:\(configuration.port)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-R", host, "-f", url.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ZooKeeperError.message("Cannot update the SSH trusted host records.")
        }
        // 工具的备份仅含旧公钥；移除它，避免保留用户已明确撤销的信任记录。
        try? FileManager.default.removeItem(atPath: url.path + ".old")
    }
}
