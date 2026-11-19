import Foundation
import Darwin

/// 直连与隧道共用的服务器地址，避免两条路径接受不同的连接串。
struct ServerAddress: Sendable {
    /// 去掉 IPv6 方括号后的主机地址。
    let host: String
    /// 经范围检查的服务端口。
    let port: Int

    /// 验证单个服务器地址，拒绝认证信息、路径和集群串。
    init(endpoint: String) throws {
        guard let url = URLComponents(string: "tcp://" + endpoint),
              let host = url.host, !host.isEmpty, let port = url.port,
              (1...65535).contains(port), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              !endpoint.contains(","), !host.contains(where: { $0.isWhitespace }),
              !host.contains("%") else {
            throw ZooKeeperError.message("请输入单个 host:port（IPv6 使用 [地址]:端口），暂不支持集群串和 chroot。")
        }
        self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        self.port = port
    }

    /// 生成可嵌入 SSH 本地转发参数的远端地址。
    var forwardingTarget: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// SSH 公钥认证配置，仅持久化连接参数与私钥路径，不保存密钥内容。
struct SSHConfiguration: Codable, Hashable, Sendable {
    /// SSH 服务器的主机名或 IP，不包含端口。
    var host = ""
    /// SSH 服务端口。
    var port = 22
    /// SSH 登录用户名。
    var username = ""
    /// 可选的私钥文件路径，为空时使用系统默认密钥或 ssh-agent。
    var identityFile = ""

    /// 校验主机、端口、用户名及显式指定的私钥文件。
    func validate() throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              !username.isEmpty, !username.hasPrefix("-"),
              username.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "._-")).contains($0) }), (1...65535).contains(port) else {
            throw ZooKeeperError.message("请填写有效的 SSH 主机、端口（1–65535）和用户名。IPv6 主机无需方括号。")
        }
        if !identityFile.isEmpty {
            let path = NSString(string: identityFile).expandingTildeInPath
            var directory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory),
                  !directory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
                throw ZooKeeperError.message("SSH 私钥文件不存在或不可读取，请选择本机私钥文件。")
            }
        }
    }

    /// 生成独立进程的参数，不经过 shell，并限制转发只监听本机回环地址。
    func arguments(target: ServerAddress, localPort: Int, controlPath: String) -> [String] {
        var args = ["-F", "/dev/null", "-N", "-T", "-n", "-M", "-S", controlPath,
                    "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
                    "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2", "-o", "ControlPersist=no",
                    "-o", "ForwardAgent=no", "-o", "PermitLocalCommand=no",
                    "-p", String(port), "-l", username,
                    "-L", "127.0.0.1:\(localPort):\(target.forwardingTarget)"]
        if !identityFile.isEmpty {
            args += ["-o", "IdentitiesOnly=yes", "-i", NSString(string: identityFile).expandingTildeInPath]
        }
        return args + ["--", host]
    }
}

/// 管理一条独立的系统 SSH 隧道，界面等待期间保持可取消。
@MainActor
final class SSHTunnel {
    /// 退出应用时需要关闭并清理的全部 SSH 隧道。
    private static var tunnels: [String: SSHTunnel] = [:]
    /// 专用 SSH 子进程，不与用户的其他 SSH 会话共享。
    private let process = Process()
    /// 系统 SSH 程序地址，测试可替换为受控进程。
    private let executableURL: URL
    /// 当前隧道独占的临时目录。
    private let directory: URL
    /// SSH 错误输出文件，避免管道缓冲区写满后阻塞。
    private let errorURL: URL
    /// 供 SSH 子进程写入的文件句柄。
    private let errorHandle: FileHandle
    /// 转发使用的本机端口。
    private let localPort: Int
    /// 标记资源已经回收，避免连接失败与显式关闭重复清理。
    private var stopped = false

    /// 分配临时目录和本机端口，目录仅允许当前用户访问。
    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws {
        self.executableURL = executableURL
        localPort = try Self.availablePort()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("csh-\(UUID().uuidString.prefix(8))")
        errorURL = directory.appendingPathComponent("error.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            errorHandle = try FileHandle(forWritingTo: errorURL)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 启动隧道，控制套接字出现后才将本机地址交给 ZooKeeper 客户端。
    func start(configuration: SSHConfiguration, endpoint: String) async throws -> String {
        do {
            try configuration.validate()
            let target = try ServerAddress(endpoint: endpoint)
            let controlPath = directory.appendingPathComponent("ctl").path
            process.executableURL = executableURL
            process.arguments = configuration.arguments(target: target, localPort: localPort, controlPath: controlPath)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle
            try Task.checkCancellation()
            try process.run()
            Self.tunnels[directory.path] = self
            for _ in 0..<240 {
                try Task.checkCancellation()
                guard process.isRunning else { throw failure() }
                if FileManager.default.fileExists(atPath: controlPath) {
                    return "127.0.0.1:\(localPort)"
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ZooKeeperError.message("SSH 隧道建立超时，请检查主机、网络与认证设置。")
        } catch {
            stop()
            throw error
        }
    }

    /// 汇总 SSH 的错误输出，并说明非交互认证和主机校验要求。
    private func failure() -> ZooKeeperError {
        let handle = try? FileHandle(forReadingFrom: errorURL)
        let data = try? handle?.read(upToCount: 4096)
        try? handle?.close()
        let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? "SSH 进程已退出。"
        return .message("SSH 隧道建立失败：\n\(detail.trimmingCharacters(in: .whitespacesAndNewlines))\n请确认密钥可用（加密私钥请先加入 ssh-agent），并先在终端校验并信任该主机。")
    }

    /// 主动结束独占隧道并清理临时文件，可重复调用。
    func stop() {
        guard !stopped else { return }
        stopped = true
        if process.isRunning { process.terminate() }
        Self.tunnels.removeValue(forKey: directory.path)
        try? errorHandle.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// 应用退出时同步通知所有 SSH 子进程结束，避免残留后台隧道。
    static func stopAll() {
        for tunnel in Array(tunnels.values) { tunnel.stop() }
    }

    /// 让系统分配空闲回环端口；竞争占用由 SSH 的转发失败检查显式报告。
    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ZooKeeperError.message("无法创建 SSH 本地转发端口。") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard result == 0, inspected == 0 else { throw ZooKeeperError.message("无法分配 SSH 本地转发端口。") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
