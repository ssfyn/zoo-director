import XCTest
@testable import ZooDirector

/// 暂停握手，让测试精确控制成功、失败及取消后的迟到结果。
private actor ConnectionGate {
    /// 显式连接尝试的累计次数。
    private(set) var attempts = 0
    /// 尚未完成的握手续体，刻意不响应任务取消以模拟迟到的网络结果。
    private var pending: CheckedContinuation<any ZooKeeperService, any Error>?

    /// 记录一次连接尝试并等待测试发布结果。
    func open() async throws -> any ZooKeeperService {
        attempts += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    /// 让等待中的握手返回指定服务。
    func succeed(_ service: any ZooKeeperService) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: service)
    }

    /// 模拟真实握手失败。
    func fail() {
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: ZooKeeperError.message("隔离测试连接失败"))
    }
}

/// 验证选择配置、显式连接、取消、关闭和断线的完整状态转换。
@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    /// 等待确定状态，避免依赖固定的网络或任务调度时长。
    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("连接状态未在预期时间内完成转换")
    }

    /// 为每个状态测试创建独立偏好设置，并在测试结束后清理。
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "ZooDirector.Lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// 启动、添加和单击只操作本机配置，重启不恢复任何网络会话。
    func testStartupAndSelectionNeverConnect() async throws {
        let suite = "ZooDirector.Lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = ConnectionGate()
        let model = BrowserModel(defaults: defaults, serviceFactory: { _ in try await gate.open() })
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNil(model.selectedProfile)
        XCTAssertNil(model.activeID)
        let first = try XCTUnwrap(model.addConnection(name: "第一台", endpoint: "localhost:2181"))
        let second = try XCTUnwrap(model.addConnection(name: "第二台", endpoint: "localhost:2182"))
        model.selectConnection(first)
        XCTAssertEqual(model.selectedProfile?.id, first.id)
        XCTAssertFalse(model.showingBrowser)
        XCTAssertFalse(model.isConnected(first))
        XCTAssertFalse(model.isConnected(second))
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 0)
        let restored = BrowserModel(defaults: defaults, serviceFactory: { _ in try await gate.open() })
        XCTAssertEqual(restored.profiles.count, 2)
        XCTAssertNil(restored.selectedProfile)
        XCTAssertNil(restored.activeID)
        XCTAssertFalse(restored.connecting)
        XCTAssertFalse(restored.connectionEstablished)
    }

    /// 握手成功后才显示绿色和节点，查看其他配置不触发新连接或关闭原会话。
    func testExplicitConnectSelectionAndClose() async throws {
        let gate = ConnectionGate()
        let service = DemoService()
        let model = BrowserModel(defaults: try isolatedDefaults(), serviceFactory: { _ in try await gate.open() })
        let first = ConnectionProfile(name: "第一台", endpoint: "localhost:2181")
        let second = ConnectionProfile(name: "第二台", endpoint: "localhost:2182")
        model.profiles = [first, second]
        model.connect(first)
        XCTAssertTrue(model.connecting)
        XCTAssertFalse(model.showingBrowser)
        XCTAssertFalse(model.isConnected(first))
        try await eventually { await gate.attempts == 1 }
        await gate.succeed(service)
        try await eventually { model.connectionEstablished && !model.loading }
        XCTAssertTrue(model.showingBrowser)
        XCTAssertTrue(model.isConnected(first))
        XCTAssertFalse(model.tree.rows.isEmpty)
        model.selectConnection(second)
        XCTAssertFalse(model.showingBrowser)
        XCTAssertTrue(model.isConnected(first))
        XCTAssertFalse(model.isConnected(second))
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 1)
        model.selectConnection(first)
        XCTAssertTrue(model.showingBrowser)
        model.disconnect()
        XCTAssertFalse(model.isConnected(first))
        XCTAssertFalse(model.showingBrowser)
        XCTAssertTrue(model.names.isEmpty)
        XCTAssertTrue(model.tree.rows.isEmpty)
        XCTAssertEqual(model.selectedProfile?.id, first.id)
        try await eventually { await service.closed }
    }

    /// 取消后的握手即使迟到成功也必须关闭；失败后保留配置供重试。
    func testCancellationRejectsLateServiceAndFailureAllowsRetry() async throws {
        let gate = ConnectionGate()
        let model = BrowserModel(defaults: try isolatedDefaults(), serviceFactory: { _ in try await gate.open() })
        let profile = ConnectionProfile(name: "测试", endpoint: "localhost:2181")
        model.profiles = [profile]
        model.connect(profile)
        try await eventually { await gate.attempts == 1 }
        model.disconnect()
        let late = DemoService()
        await gate.succeed(late)
        try await eventually { await late.closed }
        XCTAssertNil(model.activeID)
        XCTAssertFalse(model.connectionEstablished)
        XCTAssertFalse(model.connecting)
        model.connect(profile)
        try await eventually { await gate.attempts == 2 }
        await gate.fail()
        try await eventually { !model.connecting }
        XCTAssertEqual(model.selectedProfile?.id, profile.id)
        XCTAssertFalse(model.isConnected(profile))
        XCTAssertFalse(model.showingBrowser)
        XCTAssertNotNil(model.error)
    }

    /// 修改已连接的地址只关闭旧会话，不能隐式发起第二次握手。
    func testEditingConnectedAddressClosesWithoutReconnecting() async throws {
        let gate = ConnectionGate()
        let service = DemoService()
        let model = BrowserModel(defaults: try isolatedDefaults(), serviceFactory: { _ in try await gate.open() })
        let profile = ConnectionProfile(name: "测试", endpoint: "localhost:2181")
        model.profiles = [profile]
        model.connect(profile)
        try await eventually { await gate.attempts == 1 }
        await gate.succeed(service)
        try await eventually { model.connectionEstablished && !model.loading }
        model.addFavorite("/services")
        XCTAssertTrue(model.updateConnection(profile, name: "新地址", endpoint: "localhost:2182"))
        XCTAssertFalse(model.connectionEstablished)
        XCTAssertFalse(model.connecting)
        XCTAssertEqual(model.selectedProfile?.endpoint, "localhost:2182")
        let attempts = await gate.attempts
        XCTAssertEqual(attempts, 1)
        try await eventually { await service.closed }
    }

    /// 旧版本演示配置不会再出现在连接列表，也不会导致启动连接。
    func testLegacyDemoProfileIsRemoved() throws {
        let suite = "ZooDirector.Lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ConnectionProfile(name: "演示空间", endpoint: "demo", isDemo: true)
        let actual = ConnectionProfile(name: "本机", endpoint: "localhost:2181")
        defaults.set(try JSONEncoder().encode([legacy, actual]), forKey: "zoodirector.connections")
        let model = BrowserModel(defaults: defaults)
        XCTAssertEqual(model.profiles, [actual])
        XCTAssertNil(model.activeID)
        XCTAssertNil(model.selectedProfile)
    }
}
