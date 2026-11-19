import XCTest
@testable import ZooDirector

/// 控制临时测试握手的迟到响应，并记录是否使用了当前草稿。
private actor ProbeGate {
    /// 最近收到的草稿，不从持久化配置读取。
    private(set) var profile: ConnectionProfile?
    /// 等待测试决定结果的续体。
    private var pending: CheckedContinuation<any ZooKeeperService, any Error>?

    /// 保存参数并挂起模拟握手，刻意忽略取消以检验迟到资源回收。
    func open(_ profile: ConnectionProfile) async throws -> any ZooKeeperService {
        self.profile = profile
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    /// 发布握手成功的临时服务。
    func finish(_ service: any ZooKeeperService) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: service)
    }
}

/// 验证测试连接不会保存参数、改变正式会话或残留临时服务。
@MainActor
final class ConnectionTestModelTests: XCTestCase {
    /// 等待测试结果和异步关闭。
    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("临时连接测试未及时完成")
    }

    /// 使用草稿中的新地址和 SSH 参数，成功后释放独立连接并保留原会话。
    func testProbeUsesDraftAndClosesWithoutChangingActiveSession() async throws {
        let suite = "ZooDirector.ConnectionProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = ConnectionWorkspace(defaults: defaults, serviceFactory: { _ in DemoService() })
        defer { workspace.shutdown() }
        let saved = try XCTUnwrap(workspace.configuration.addConnection(name: "原配置", endpoint: "original:2181"))
        workspace.connect(saved)
        let session = try XCTUnwrap(workspace.session(for: saved))
        try await eventually { session.connectionEstablished && !session.loading }
        let persisted = defaults.data(forKey: "zoodirector.connections")
        let gate = ProbeGate()
        let probe = ConnectionTestModel(factory: { try await gate.open($0) })
        let draft = ConnectionProfile(name: "", endpoint: "changed:2182",
                                     ssh: SSHConfiguration(host: "jump.example.com", username: "operator"))
        probe.start(draft)
        XCTAssertTrue(probe.running)
        try await eventually { await gate.profile != nil }
        let received = await gate.profile
        XCTAssertEqual(received, draft)
        let temporary = DemoService()
        await gate.finish(temporary)
        try await eventually { !probe.running }
        XCTAssertTrue(probe.succeeded)
        XCTAssertNotNil(probe.message)
        let closed = await temporary.closed
        XCTAssertTrue(closed)
        XCTAssertTrue(session.isConnected(saved))
        XCTAssertEqual(workspace.current.selectedProfile, saved)
        XCTAssertEqual(defaults.data(forKey: "zoodirector.connections"), persisted)
    }

    /// 取消后返回的服务仍需释放，不能显示过期的成功提示。
    func testCancelledProbeClosesLateService() async throws {
        let gate = ProbeGate()
        let probe = ConnectionTestModel(factory: { try await gate.open($0) })
        probe.start(ConnectionProfile(name: "", endpoint: "localhost:2181"))
        try await eventually { await gate.profile != nil }
        probe.cancel()
        let service = DemoService()
        await gate.finish(service)
        try await eventually { await service.closed }
        XCTAssertFalse(probe.running)
        XCTAssertFalse(probe.succeeded)
        XCTAssertNil(probe.message)
    }

    /// 认证或网络失败应清除加载状态并显示原始错误，修改参数可清除旧结果。
    func testFailureReportsReasonAndCanBeCleared() async throws {
        let probe = ConnectionTestModel(factory: { _ in throw ZooKeeperError.message("SSH 认证失败") })
        probe.start(ConnectionProfile(name: "", endpoint: "localhost:2181"))
        try await eventually { !probe.running }
        XCTAssertFalse(probe.succeeded)
        XCTAssertTrue(probe.message?.contains("SSH 认证失败") == true)
        probe.cancel()
        XCTAssertNil(probe.message)
    }
}
