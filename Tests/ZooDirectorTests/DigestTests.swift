import Foundation
import CryptoKit
import XCTest
@testable import ZooDirector

/// 测试使用的线程安全内存凭据库，不访问用户真实钥匙串。
final class MemoryDigestPasswordStore: DigestPasswordStore, @unchecked Sendable {
    /// 保护密码和故障开关的互斥锁。
    private let lock = NSLock()
    /// 按随机引用保存测试密码。
    private var passwords: [UUID: String] = [:]
    /// 模拟钥匙串保存失败，不影响已有值。
    private var shouldRejectWrites = false
    /// 线程安全地控制下一次保存是否失败。
    var rejectWrites: Bool {
        get { lock.withLock { shouldRejectWrites } }
        set { lock.withLock { shouldRejectWrites = newValue } }
    }

    /// 返回测试密码，包括有效的空密码。
    func load(_ id: UUID) throws -> String? { lock.withLock { passwords[id] } }

    /// 模拟独立存储成功或授权失败。
    func save(_ password: String, id: UUID) throws {
        try lock.withLock {
            if shouldRejectWrites { throw ZooKeeperError.message("测试钥匙串拒绝写入") }
            passwords[id] = password
        }
    }

    /// 删除指定测试条目。
    func remove(_ id: UUID) throws { _ = lock.withLock { passwords.removeValue(forKey: id) } }
}

/// 验证旧配置兼容、密码隔离和多连接认证变更行为。
@MainActor
final class DigestTests: XCTestCase {
    /// 等待异步会话建立或关闭，超时明确失败。
    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("认证连接状态未及时更新")
    }

    /// 旧配置不启用认证；用户名保留原文并拒绝协议分隔符。
    func testConfigurationCompatibilityAndValidation() throws {
        let old = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"old\",\"endpoint\":\"localhost:2181\",\"isDemo\":false}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ConnectionProfile.self, from: old).digest)
        for username in ["", "a:b", "a\0b"] {
            XCTAssertThrowsError(try DigestConfiguration(username: username).validate())
        }
        try DigestConfiguration(username: " 用户 ").validate()
    }

    /// 新建、改名、换密码、禁用与删除均保持密码独立，不留下失效引用。
    func testCredentialLifecycleAndPersistence() throws {
        let suite = "ZooDirector.Digest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryDigestPasswordStore()
        let model = BrowserModel(defaults: defaults, passwordStore: store)
        let first = try XCTUnwrap(model.addConnection(name: "认证", endpoint: "localhost:2181",
            digest: DigestConfiguration(username: "tester"), password: "initial-secret"))
        let reference = try XCTUnwrap(first.digest?.credentialID)
        XCTAssertEqual(try store.load(reference), "initial-secret")
        let encoded = try XCTUnwrap(defaults.data(forKey: "zoodirector.connections"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("initial-secret"))
        XCTAssertEqual(BrowserModel(defaults: defaults, passwordStore: store).profiles.first?.digest, first.digest)
        XCTAssertTrue(model.updateConnection(first, name: "改名", endpoint: first.endpoint, digest: first.digest))
        XCTAssertEqual(model.profiles.first?.digest?.credentialID, reference)
        XCTAssertTrue(model.updateConnection(first, name: "改密码", endpoint: first.endpoint, digest: first.digest, password: ""))
        let rotated = try XCTUnwrap(model.profiles.first)
        let next = try XCTUnwrap(rotated.digest?.credentialID)
        XCTAssertNotEqual(reference, next)
        XCTAssertNil(try store.load(reference))
        XCTAssertEqual(try store.load(next), "")
        XCTAssertTrue(model.updateConnection(rotated, name: "关闭认证", endpoint: rotated.endpoint))
        XCTAssertNil(try store.load(next))
        let last = try XCTUnwrap(model.addConnection(name: "删除", endpoint: first.endpoint,
            digest: DigestConfiguration(username: "tester"), password: "test-only"))
        model.deleteConnection(last)
        XCTAssertNil(try store.load(try XCTUnwrap(last.digest?.credentialID)))
    }

    /// 钥匙串失败时保留原配置及密码，不将半成品持久化。
    func testPasswordFailureLeavesConfigurationIntact() throws {
        let suite = "ZooDirector.DigestFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryDigestPasswordStore()
        let model = BrowserModel(defaults: defaults, passwordStore: store)
        let original = try XCTUnwrap(model.addConnection(name: "原配置", endpoint: "localhost:2181",
            digest: DigestConfiguration(username: "tester"), password: "original"))
        store.rejectWrites = true
        XCTAssertFalse(model.updateConnection(original, name: "修改", endpoint: "localhost:2182", digest: original.digest, password: "new"))
        XCTAssertEqual(model.profiles.first, original)
        XCTAssertEqual(try store.load(try XCTUnwrap(original.digest?.credentialID)), "original")
        XCTAssertNil(model.addConnection(name: "失败", endpoint: "localhost:2181", digest: original.digest, password: "new"))
        XCTAssertEqual(model.profiles.count, 1)
    }

    /// 修改认证仅关闭目标会话；单纯改名保留会话，换密码失败也不能断开。
    func testAuthenticationChangesOnlyCloseTargetSession() async throws {
        let suite = "ZooDirector.DigestWorkspace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryDigestPasswordStore()
        let workspace = ConnectionWorkspace(defaults: defaults, serviceFactory: { _ in DemoService() }, passwordStore: store)
        defer { workspace.shutdown() }
        let first = try XCTUnwrap(workspace.configuration.addConnection(name: "第一台", endpoint: "first:2181",
            digest: DigestConfiguration(username: "tester"), password: "original"))
        let second = try XCTUnwrap(workspace.configuration.addConnection(name: "第二台", endpoint: "second:2181"))
        workspace.connect(first); workspace.connect(second)
        let target = try XCTUnwrap(workspace.session(for: first))
        let other = try XCTUnwrap(workspace.session(for: second))
        try await eventually { target.connectionEstablished && other.connectionEstablished && !target.loading && !other.loading }
        XCTAssertTrue(workspace.update(first, name: "改名", endpoint: first.endpoint, ssh: nil, digest: first.digest))
        XCTAssertTrue(target.connectionEstablished)
        store.rejectWrites = true
        XCTAssertFalse(workspace.update(first, name: "失败", endpoint: first.endpoint, ssh: nil, digest: first.digest, password: "new"))
        XCTAssertTrue(target.connectionEstablished)
        store.rejectWrites = false
        XCTAssertTrue(workspace.update(first, name: "新密码", endpoint: first.endpoint, ssh: nil, digest: first.digest, password: "new"))
        XCTAssertFalse(target.connectionEstablished)
        XCTAssertTrue(other.connectionEstablished)
    }

    /// 缺少密码时在网络建立前失败，不回退成匿名连接。
    func testMissingPasswordNeverConnectsAnonymously() async {
        let profile = ConnectionProfile(name: "缺失密码", endpoint: "localhost:2181", digest: DigestConfiguration(username: "tester"))
        do {
            _ = try await ZooKeeperClient.open(profile: profile, passwordStore: MemoryDigestPasswordStore())
            XCTFail("缺少密码必须拒绝建立匿名会话")
        } catch { XCTAssertTrue(error.localizedDescription.contains("No digest password")) }
    }

    /// 显式启用时只操作唯一临时钥匙串条目，完成后删除，不读取用户密码。
    func testSystemKeychainRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["ZOODIRECTOR_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("设置 ZOODIRECTOR_KEYCHAIN_TEST=1 可验证系统钥匙串")
        }
        let store = KeychainDigestPasswordStore()
        let id = UUID()
        defer { try? store.remove(id) }
        XCTAssertNil(try store.load(id))
        try store.save("test-only-" + id.uuidString, id: id)
        XCTAssertEqual(try store.load(id), "test-only-" + id.uuidString)
        try store.remove(id)
        XCTAssertNil(try store.load(id))
    }

    /// 独立原始会话创建受保护目录，正式客户端先认证再读写并安装监听。
    func testLiveDigestProtectedNodesAndWatch() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ZOODIRECTOR_TEST_ENDPOINT"] else {
            throw XCTSkip("设置隔离 ZOODIRECTOR_TEST_ENDPOINT 后验证真实 digest ACL")
        }
        let peer = try ZooKeeperMutationPeer(endpoint)
        try await peer.connect()
        let base = "/zoodirector-digest-" + UUID().uuidString
        let username = "digest-tester", password = "test-only:" + UUID().uuidString
        let hash = Data(Insecure.SHA1.hash(data: Data("\(username):\(password)".utf8))).base64EncodedString()
        let store = MemoryDigestPasswordStore()
        let config = DigestConfiguration(username: username)
        try store.save(password, id: config.credentialID)
        let profile = ConnectionProfile(name: "认证隔离测试", endpoint: endpoint, digest: config)
        let client = try await ZooKeeperClient.open(profile: profile, passwordStore: store)
        let anonymous = try await ZooKeeperClient.open(profile: ConnectionProfile(name: "匿名", endpoint: endpoint))
        let wrong = try await ZooKeeperClient.open(profile: profile, password: "wrong-test-only")
        let log = WatchEventLog()
        let stream = await client.watchEvents()
        let consumer = Task { for await event in stream { await log.append(event) } }
        do {
            try await peer.create(base, text: "private", digestIdentity: "\(username):\(hash)")
            let value = try await client.read(base)
            XCTAssertEqual(value.data, Data("private".utf8))
            try await expectNoAccess(anonymous, path: base)
            try await expectNoAccess(wrong, path: base)
            await client.watch([base], owner: UUID(), revision: 1)
            try await eventually { await log.synchronized(base) }
            try await client.create(base + "/child", data: Data("protected child".utf8), ephemeral: false)
            try await expectNoAccess(anonymous, path: base + "/child")
            try await expectNoAccess(wrong, path: base + "/child")
            try await eventually { await log.events.contains { if case .changed(base, .children) = $0 { return true }; return false } }
            _ = try await NodeMutations.delete(paths: [base], recursive: true, service: client)
        } catch {
            _ = try? await NodeMutations.delete(paths: [base], recursive: true, service: client)
            await client.close(); await anonymous.close(); await wrong.close(); await peer.close()
            consumer.cancel()
            throw error
        }
        await client.close(); await anonymous.close(); await wrong.close(); await peer.close()
        consumer.cancel()
    }

    /// 无身份或错误密码必须收到节点权限错误，不能将认证握手当作权限校验。
    private func expectNoAccess(_ client: ZooKeeperClient, path: String) async throws {
        do { _ = try await client.read(path); XCTFail("受保护节点不能被无权限身份读取") }
        catch ZooKeeperError.server(-102) {}
    }

}
