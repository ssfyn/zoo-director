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
            throw ZooKeeperError.message("Enter a single host:port (use [address]:port for IPv6). Server lists and chroot paths are not supported yet.")
        }
        self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        self.port = port
    }

    /// 生成可嵌入 SSH 本地转发参数的远端地址。
    var forwardingTarget: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// SSH 公钥认证配置，仅持久化连接参数、显示路径及用户授予的文件书签。
struct SSHConfiguration: Codable, Hashable, Sendable {
    /// SSH 服务器的主机名或 IP，不包含端口。
    var host = ""
    /// SSH 服务端口。
    var port = 22
    /// SSH 登录用户名。
    var username = ""
    /// 用户选择的私钥显示路径，不作为文件访问授权。
    var identityFile = ""
    /// 私钥文件的持久只读授权；旧配置缺失时要求用户重新选择。
    var identityBookmark: Data?

    /// 校验服务器配置和用户授权的私钥文件。
    func validate() throws {
        try validateServer()
        _ = try SSHPrivateKey.read(bookmark: identityBookmark)
    }

    /// 单独校验服务器身份，让撤销旧公钥时无需读取私钥。
    func validateServer() throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              !username.isEmpty, !username.hasPrefix("-"),
              username.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "._-")).contains($0) }), (1...65535).contains(port) else {
            throw ZooKeeperError.message("Enter a valid SSH host, port (1–65535), and username. IPv6 hosts do not need brackets.")
        }
    }

    /// 生成独立进程的参数，不经过 shell，并限制转发只监听本机回环地址。
    func arguments(target: ServerAddress, localPort: Int, controlPath: String,
                   identityPath: String, knownHostsPath: String) -> [String] {
        let args = ["-F", "/dev/null", "-N", "-T", "-n", "-M", "-S", controlPath,
                    "-o", "BatchMode=no", "-o", "StrictHostKeyChecking=ask",
                    "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
                    "-o", "KbdInteractiveAuthentication=no", "-o", "IdentityAgent=none",
                    "-o", "IdentitiesOnly=yes", "-o", "AddKeysToAgent=no",
                    "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"", "-o", "GlobalKnownHostsFile=/dev/null",
                    "-o", "HashKnownHosts=yes", "-o", "UpdateHostKeys=no",
                    "-o", "VerifyHostKeyDNS=no", "-i", identityPath,
                    "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",
                    "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=2", "-o", "ControlPersist=no",
                    "-o", "ForwardAgent=no", "-o", "PermitLocalCommand=no",
                    "-p", String(port), "-l", username,
                    "-L", "127.0.0.1:\(localPort):\(target.forwardingTarget)"]
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
    /// 继承沙箱权限的图形确认辅助程序。
    private let askpassURL: URL
    /// 应用自己维护的服务器公钥记录，可注入隔离位置进行测试。
    private let knownHostsURL: URL
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
    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"), askpassURL: URL? = nil,
         knownHostsURL: URL? = nil) throws {
        self.executableURL = executableURL
        self.askpassURL = askpassURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/ZooDirectorSSHAskpass.app/Contents/MacOS/ZooDirectorSSHAskpass")
        self.knownHostsURL = try knownHostsURL ?? SSHKnownHosts.location()
        localPort = try Self.availablePort()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-\(UUID().uuidString)")
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
            try Task.checkCancellation()
            try configuration.validate()
            let target = try ServerAddress(endpoint: endpoint)
            let controlPath = directory.appendingPathComponent("ctl").path
            try prepareProcess(configuration: configuration, target: target, controlPath: "ctl")
            try Task.checkCancellation()
            try process.run()
            Self.tunnels[directory.path] = self
            for _ in 0..<3_600 {
                try Task.checkCancellation()
                guard process.isRunning else { throw failure() }
                if FileManager.default.fileExists(atPath: controlPath) {
                    // 认证结束即移除临时私钥，不在整个连接期间保留额外副本。
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent("identity"))
                    return "127.0.0.1:\(localPort)"
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ZooKeeperError.message("The SSH tunnel timed out. Check the host, network, and authentication settings.")
        } catch {
            stop()
            throw error
        }
    }

    /// 准备应用私有的密钥副本和主机记录，不让子进程访问用户的系统 SSH 配置。
    private func prepareProcess(configuration: SSHConfiguration, target: ServerAddress, controlPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: askpassURL.path) else {
            throw ZooKeeperError.message("The SSH authorization helper is missing. Rebuild or reinstall ZooDirector.")
        }
        let identity = try SSHPrivateKey.stage(bookmark: configuration.identityBookmark, in: directory)
        let trustDirectory = knownHostsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: trustDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            guard FileManager.default.createFile(atPath: knownHostsURL.path, contents: Data(),
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw ZooKeeperError.message("Cannot create the SSH trusted host records.")
            }
        }
        process.executableURL = executableURL
        // 容器路径较长，控制套接字使用会话目录下的相对路径，避免超过系统上限。
        process.currentDirectoryURL = directory
        process.arguments = configuration.arguments(target: target, localPort: localPort, controlPath: controlPath,
                                                    identityPath: identity.path, knownHostsPath: knownHostsURL.path)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SSH_AUTH_SOCK")
        environment["SSH_ASKPASS"] = askpassURL.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = ":0"
        environment["ZOODIRECTOR_SSH_LANGUAGE"] = LanguagePreferences.shared.resolvedLanguage
        environment["ZOODIRECTOR_SSH_CONTEXT"] = "\(configuration.username)@\(configuration.host):\(configuration.port)\n"
            + URL(fileURLWithPath: configuration.identityFile).lastPathComponent
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle
    }

    /// 汇总 SSH 错误，主机密钥变化必须由用户核实，不能自动接受。
    private func failure() -> ZooKeeperError {
        let handle = try? FileHandle(forReadingFrom: errorURL)
        let data = try? handle?.read(upToCount: 4096)
        try? handle?.close()
        let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? "The SSH process exited."
        return .message("Could not establish the SSH tunnel:\n\(detail.trimmingCharacters(in: .whitespacesAndNewlines))\nCheck the selected private key and passphrase. If the server fingerprint changed, verify it with your administrator before reconnecting.")
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
        guard descriptor >= 0 else { throw ZooKeeperError.message("Could not create a local SSH forwarding port.") }
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
        guard result == 0, inspected == 0 else { throw ZooKeeperError.message("Could not allocate a local SSH forwarding port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
