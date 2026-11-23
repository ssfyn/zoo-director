import XCTest
import Darwin
@testable import ZooDirector

/// 验证旧配置兼容、公钥认证参数和隧道失败时的资源回收。
@MainActor
final class SSHTests: XCTestCase {
    /// 旧版连接可直接解码，编辑后的 SSH 配置与原收藏同时保留。
    func testLegacyProfileAndSSHPersistence() throws {
        let original = ConnectionProfile(name: "旧连接", endpoint: "localhost:2181")
        let encoded = try JSONEncoder().encode(original)
        XCTAssertNil(try JSONDecoder().decode(ConnectionProfile.self, from: encoded).ssh)
        let suite = "ZooDirector.SSH.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([original]), forKey: "zoodirector.connections")
        defaults.set(try JSONEncoder().encode([original.id.uuidString: ["/services"]]), forKey: "zoodirector.favorites")
        let model = BrowserModel(defaults: defaults)
        let ssh = try configuration(host: "bastion.example.com", port: 2222, username: "operator")
        XCTAssertTrue(model.updateConnection(original, name: "隧道连接", endpoint: "zk.internal:2181", ssh: ssh))
        let restored = BrowserModel(defaults: defaults)
        XCTAssertEqual(restored.profiles.first { $0.id == original.id }?.ssh, ssh)
        restored.activeID = original.id
        XCTAssertEqual(restored.favorites, ["/services"])
        XCTAssertTrue(model.updateConnection(original, name: "直连", endpoint: "localhost:2181"))
        XCTAssertNil(BrowserModel(defaults: defaults).profiles.first { $0.id == original.id }?.ssh)
    }

    /// 拒绝无效主机、端口、用户名及不可读取的私钥。
    func testConfigurationValidation() throws {
        for host in ["-option", "user@host", "host:22/path", "host name", "host\nname", "$(command)"] {
            XCTAssertThrowsError(try SSHConfiguration(host: host, username: "operator").validate())
        }
        for username in ["", "-root", "user@host", "user name"] {
            XCTAssertThrowsError(try SSHConfiguration(host: "localhost", username: username).validate())
        }
        for port in [0, 65536] {
            XCTAssertThrowsError(try SSHConfiguration(host: "localhost", port: port, username: "operator").validate())
        }
        XCTAssertThrowsError(try SSHConfiguration(host: "localhost", username: "operator",
                                                 identityFile: "/nonexistent/zoodirector-key").validate())
        try configuration(host: "::1", username: "operator").validate()
        XCTAssertEqual(try ServerAddress(endpoint: "[::1]:2181").forwardingTarget, "[::1]:2181")
    }

    /// 由系统 SSH 解析实际参数，确认转发、独立主机记录和仅公钥认证。
    func testSystemSSHAcceptsForwardingOptions() throws {
        let configuration = SSHConfiguration(host: "localhost", port: 2222, username: "operator")
        let args = configuration.arguments(target: try ServerAddress(endpoint: "[::1]:2181"),
                                           localPort: 32181, controlPath: "/tmp/zoodirector-test-ctl",
                                           identityPath: "/tmp/authorized-key", knownHostsPath: "/tmp/app trust/known_hosts")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G"] + args
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("batchmode no"))
        XCTAssertTrue(text.contains("identityagent none"))
        XCTAssertTrue(text.contains("passwordauthentication no"))
        XCTAssertTrue(text.contains("userknownhostsfile /tmp/app trust/known_hosts"))
        XCTAssertTrue(text.contains("stricthostkeychecking ask"))
        XCTAssertTrue(text.contains("exitonforwardfailure yes"))
        XCTAssertTrue(text.contains("localforward [127.0.0.1]:32181 [::1]:2181"))
        XCTAssertTrue(text.contains("user operator"))
        XCTAssertTrue(text.contains("port 2222"))
    }

    /// 预先取消的连接不得启动 SSH；本机关闭端口应快速返回明确的隧道错误。
    func testCancellationAndSSHFailure() async throws {
        let tunnel = try makeTunnel()
        let task = Task { @MainActor in
            try await tunnel.start(configuration: try configuration(host: "127.0.0.1", port: 1, username: "operator"),
                                   endpoint: "localhost:2181")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("已取消的隧道不能建立") }
        catch { XCTAssertTrue(error is CancellationError) }
        let failing = try makeTunnel()
        do {
            _ = try await failing.start(configuration: try configuration(host: "127.0.0.1", port: 1, username: "operator"),
                                        endpoint: "localhost:2181")
            XCTFail("关闭端口不应建立隧道")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Could not establish the SSH tunnel")) }
        failing.stop()
        SSHTunnel.stopAll()
    }

    /// 显式提供隔离 SSH 与 ZooKeeper 服务时，验证真实隧道中的握手和只读请求。
    func testLiveSSHConnection() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["ZOODIRECTOR_TEST_SSH_HOST"],
              let username = environment["ZOODIRECTOR_TEST_SSH_USER"],
              let target = environment["ZOODIRECTOR_TEST_SSH_TARGET"] else {
            throw XCTSkip("配置 ZOODIRECTOR_TEST_SSH_HOST、USER、TARGET 可验证隔离 SSH 隧道")
        }
        guard let key = environment["ZOODIRECTOR_TEST_SSH_KEY"],
              let knownHosts = environment["ZOODIRECTOR_TEST_SSH_KNOWN_HOSTS"] else {
            throw XCTSkip("真实测试需要显式指定私钥和已核实的隔离服务器公钥文件")
        }
        let configuration = SSHConfiguration(host: host,
            port: Int(environment["ZOODIRECTOR_TEST_SSH_PORT"] ?? "22") ?? 22,
            username: username, identityFile: key,
            identityBookmark: try SSHPrivateKey.bookmark(for: URL(fileURLWithPath: key)))
        let executable = URL(fileURLWithPath: environment["ZOODIRECTOR_TEST_SSH_EXECUTABLE"] ?? "/usr/bin/ssh")
        let tunnel = try SSHTunnel(executableURL: executable, askpassURL: URL(fileURLWithPath: "/usr/bin/false"),
                                  knownHostsURL: URL(fileURLWithPath: knownHosts))
        defer { tunnel.stop() }
        let endpoint = try await tunnel.start(configuration: configuration, endpoint: target)
        let client = try ZooKeeperClient(endpoint: endpoint, tunnel: tunnel)
        do {
            try await client.connect()
            let children = try await client.children("/")
            XCTAssertTrue(children.contains("zookeeper"))
            let snapshot = try await client.read("/zookeeper")
            XCTAssertGreaterThanOrEqual(snapshot.stat.version, 0)
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }

    /// 用受控子进程验证隧道就绪后的关闭与重复关闭，防止留下后台进程。
    func testReadyTunnelStopsItsProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try fixture(in: directory, ready: true)
        let tunnel = try makeTunnel(executableURL: executable)
        defer { tunnel.stop() }
        let endpoint = try await tunnel.start(configuration: try configuration(host: "localhost", username: "operator"),
                                               endpoint: "zk.internal:2181")
        XCTAssertEqual(try ServerAddress(endpoint: endpoint).host, "127.0.0.1")
        let pid = try fixturePID(in: directory)
        XCTAssertEqual(kill(pid, 0), 0)
        SSHTunnel.stopAll()
        tunnel.stop()
        try await assertStopped(pid)
    }

    /// 建立过程中取消必须终止已启动的 SSH 子进程，而非等待连接超时。
    func testCancellationStopsStartingProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try fixture(in: directory, ready: false)
        let tunnel = try makeTunnel(executableURL: executable)
        defer { tunnel.stop() }
        let task = Task { @MainActor in
            try await tunnel.start(configuration: try configuration(host: "localhost", username: "operator"),
                                   endpoint: "zk.internal:2181")
        }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pid = try fixturePID(in: directory)
        task.cancel()
        do { _ = try await task.value; XCTFail("建立过程必须可取消") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await assertStopped(pid)
    }


    /// 创建具有真实文件书签的隔离配置，不读取开发者的任何私钥。
    private func configuration(host: String, port: Int = 22, username: String) throws -> SSHConfiguration {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("fixture-key")
        try Data("test-only-private-key".utf8).write(to: key)
        return SSHConfiguration(host: host, port: port, username: username, identityFile: key.path,
                                identityBookmark: try SSHPrivateKey.bookmark(for: key))
    }

    /// 用隔离的主机记录和无交互辅助程序构建测试隧道。
    private func makeTunnel(executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) throws -> SSHTunnel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SSHTunnel(executableURL: executableURL, askpassURL: URL(fileURLWithPath: "/usr/bin/false"),
                             knownHostsURL: directory.appendingPathComponent("known_hosts"))
    }

    /// 旧配置可解码但不能依赖保存的路径绕过文件授权。
    func testLegacySSHRequiresFileAuthorization() throws {
        let data = Data(#"{"host":"localhost","port":22,"username":"operator","identityFile":"/tmp/key"}"#.utf8)
        let old = try JSONDecoder().decode(SSHConfiguration.self, from: data)
        XCTAssertNil(old.identityBookmark)
        XCTAssertThrowsError(try old.validate())
        XCTAssertThrowsError(try SSHPrivateKey.read(bookmark: Data("invalid".utf8)))
    }

    /// 私钥暂存文件保持内容且仅当前用户可读写，不在配置中保存私钥正文。
    func testPrivateKeyStagingPermissionsAndRoundTrip() throws {
        let config = try configuration(host: "localhost", username: "operator")
        let restored = try JSONDecoder().decode(SSHConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(try SSHPrivateKey.read(bookmark: restored.identityBookmark), Data("test-only-private-key".utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = try SSHPrivateKey.stage(bookmark: restored.identityBookmark, in: directory)
        let permissions = try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: staged), Data("test-only-private-key".utf8))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("test-only-private-key"))
    }

    /// 文件授权不能让目录、空文件或超出限制的数据作为私钥进入子进程。
    func testPrivateKeyRejectsInvalidFileSizesAndDirectories() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try SSHPrivateKey.read(bookmark: SSHPrivateKey.bookmark(for: directory)))
        let file = directory.appendingPathComponent("key")
        try Data().write(to: file)
        XCTAssertThrowsError(try SSHPrivateKey.read(bookmark: SSHPrivateKey.bookmark(for: file)))
        try Data(repeating: 0, count: 1_048_577).write(to: file)
        XCTAssertThrowsError(try SSHPrivateKey.read(bookmark: SSHPrivateKey.bookmark(for: file)))
    }

    /// 撤销服务器身份兼容散列记录，且不移除其他服务器的信任。
    func testForgetHashedHostPreservesOtherServers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("known_hosts")
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        try "[target.example]:2222 \(key)\nother.example \(key)\n".write(to: file, atomically: true, encoding: .utf8)
        let hash = Process()
        hash.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        hash.arguments = ["-H", "-f", file.path]
        hash.standardOutput = FileHandle.nullDevice
        hash.standardError = FileHandle.nullDevice
        try hash.run()
        hash.waitUntilExit()
        XCTAssertEqual(hash.terminationStatus, 0)
        let before = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(before.count, 2)
        XCTAssertTrue(before[0].hasPrefix("|1|"))
        try SSHKnownHosts.forget(SSHConfiguration(host: "target.example", port: 2222, username: "operator"), file: file)
        let after = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(after, [before[1]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".old"))
    }

    /// 创建模拟控制套接字就绪信号的进程，仅用于验证进程生命周期。
    private func fixture(in directory: URL, ready: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("ssh-fixture")
        let marker = directory.appendingPathComponent("pid").path.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = """
        #!/bin/sh
        # 提取控制套接字位置，记录进程标识供测试观察。
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-S" ]; then control="$2"; shift 2; else shift; fi
        done
        printf '%s' "$$" > '\(marker)'
        \(ready ? "touch \"$control\"" : ":")
        exec /bin/sleep 30
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    /// 读取受控 SSH 进程标识，以验证关闭发生在实际子进程上。
    private func fixturePID(in directory: URL) throws -> pid_t {
        let text = try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
        return try XCTUnwrap(Int32(text))
    }

    /// 给系统短暂时间回收子进程，并检查进程已经不存在。
    private func assertStopped(_ pid: pid_t) async throws {
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("SSH 子进程关闭后仍在运行")
    }

}
