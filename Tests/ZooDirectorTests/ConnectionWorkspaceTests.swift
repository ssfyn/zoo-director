import XCTest
@testable import ZooDirector

/// 记录每个独立连接生成的服务，以验证关闭时只回收指定会话。
private actor WorkspaceServicePool {
    /// 每个连接最近建立的隔离服务。
    private var services: [UUID: DemoService] = [:]
    /// 真实执行的握手尝试次数。
    private(set) var attempts = 0

    /// 每次握手返回独立服务，模拟不同服务器与不同 SSH 隧道。
    func open(_ profile: ConnectionProfile) -> DemoService {
        let service = DemoService()
        services[profile.id] = service
        attempts += 1
        return service
    }

    /// 读取服务关闭状态，未建立的连接不视为已关闭。
    func closed(_ profile: ConnectionProfile) async -> Bool { await services[profile.id]?.closed ?? false }
}

/// 验证多个会话的浏览状态、编辑保护、收藏与配置持久化彼此独立。
@MainActor
final class ConnectionWorkspaceTests: XCTestCase {
    /// 为测试分配独立配置存储并注册清理。
    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "ZooDirector.MultiConnection.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// 等待跨任务状态，不依赖固定握手或目录读取耗时。
    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("多连接状态未在预期时间内完成更新")
    }

    /// 新增配置不联网，两个服务可同时握手、保持会话并恢复各自目录与未保存编辑。
    func testParallelConnectionsPreserveIndependentState() async throws {
        let pool = WorkspaceServicePool()
        let defaults = try isolatedDefaults()
        let workspace = ConnectionWorkspace(defaults: defaults, serviceFactory: { await pool.open($0) })
        defer { workspace.shutdown() }
        XCTAssertNil(workspace.current.selectedProfile)
        let first = try XCTUnwrap(workspace.configuration.addConnection(name: "第一台", endpoint: "first:2181"))
        let second = try XCTUnwrap(workspace.configuration.addConnection(name: "第二台", endpoint: "second:2181"))
        XCTAssertTrue(workspace.sessions.isEmpty)
        let restarted = ConnectionWorkspace(defaults: defaults, serviceFactory: { await pool.open($0) })
        XCTAssertEqual(restarted.current.selectedProfile, first)
        XCTAssertEqual(restarted.configuration.selectedConnectionID, first.id)
        XCTAssertNil(restarted.current.activeID)
        XCTAssertFalse(restarted.current.connectionEstablished)
        XCTAssertFalse(restarted.current.connecting)
        XCTAssertFalse(restarted.current.showingBrowser)
        let attempts = await pool.attempts
        XCTAssertEqual(attempts, 0)
        workspace.connect(first)
        workspace.connect(second)
        let left = try XCTUnwrap(workspace.session(for: first))
        let right = try XCTUnwrap(workspace.session(for: second))
        try await eventually { left.connectionEstablished && right.connectionEstablished && !left.loading && !right.loading }
        left.navigate("/services")
        right.navigate("/configuration")
        try await eventually { !left.loading && !right.loading }
        left.select("/services/api")
        try await eventually { !left.reading && left.snapshot != nil }
        left.editor += "未保存"
        workspace.select(second)
        XCTAssertTrue(workspace.current === right)
        XCTAssertEqual(right.path, "/configuration")
        workspace.select(first)
        XCTAssertTrue(workspace.current === left)
        XCTAssertEqual(left.path, "/services")
        XCTAssertTrue(left.editor.hasSuffix("未保存"))
        XCTAssertTrue(workspace.dirty)
        XCTAssertTrue(left.isConnected(first))
        XCTAssertTrue(right.isConnected(second))
        workspace.disconnect(second)
        try await eventually { await pool.closed(second) }
        XCTAssertTrue(left.isConnected(first))
        XCTAssertTrue(left.dirty)
        let firstClosed = await pool.closed(first)
        XCTAssertFalse(firstClosed)
    }

    /// 两个会话交替收藏及删除配置时，不能覆盖另一个连接的收藏和活动状态。
    func testFavoritesAndConfigurationChangesAreIsolated() async throws {
        let defaults = try isolatedDefaults()
        let pool = WorkspaceServicePool()
        let workspace = ConnectionWorkspace(defaults: defaults, serviceFactory: { await pool.open($0) })
        defer { workspace.shutdown() }
        let first = try XCTUnwrap(workspace.configuration.addConnection(name: "第一台", endpoint: "first:2181"))
        let second = try XCTUnwrap(workspace.configuration.addConnection(name: "第二台", endpoint: "second:2181"))
        workspace.connect(first); workspace.connect(second)
        let left = try XCTUnwrap(workspace.session(for: first))
        let right = try XCTUnwrap(workspace.session(for: second))
        try await eventually { left.connectionEstablished && right.connectionEstablished && !left.loading && !right.loading }
        left.addFavorite("/services")
        right.addFavorite("/configuration")
        left.addFavorite("/applications")
        let restored = BrowserModel(defaults: defaults)
        restored.activeID = first.id
        XCTAssertEqual(restored.favorites, ["/services", "/applications"])
        restored.activeID = second.id
        XCTAssertEqual(restored.favorites, ["/configuration"])
        XCTAssertTrue(workspace.update(first, name: "新名称", endpoint: "changed:2181", ssh: nil))
        XCTAssertFalse(left.connectionEstablished)
        XCTAssertTrue(right.connectionEstablished)
        XCTAssertEqual(BrowserModel(defaults: defaults).profiles.count, 2)
        workspace.delete(first)
        XCTAssertNil(workspace.session(for: first))
        XCTAssertTrue(right.connectionEstablished)
        let afterDeletion = BrowserModel(defaults: defaults)
        XCTAssertEqual(afterDeletion.profiles, [second])
        afterDeletion.activeID = second.id
        XCTAssertEqual(afterDeletion.favorites, ["/configuration"])
    }

    /// 未显示的会话也参与退出保护，不能误删后台存在未保存内容的连接。
    func testBackgroundSessionProtectionAndShutdown() async throws {
        let workspace = ConnectionWorkspace(defaults: try isolatedDefaults(), serviceFactory: { _ in DemoService() })
        defer { workspace.shutdown() }
        let first = try XCTUnwrap(workspace.configuration.addConnection(name: "第一台", endpoint: "first:2181"))
        let second = try XCTUnwrap(workspace.configuration.addConnection(name: "第二台", endpoint: "second:2181"))
        workspace.connect(first); workspace.connect(second)
        let left = try XCTUnwrap(workspace.session(for: first))
        let right = try XCTUnwrap(workspace.session(for: second))
        try await eventually { left.connectionEstablished && right.connectionEstablished && !left.loading && !right.loading }
        left.snapshot = NodeSnapshot(data: Data("原文".utf8), stat: NodeStat())
        left.editor = "未保存"
        workspace.select(second)
        XCTAssertTrue(workspace.dirty)
        workspace.delete(first)
        XCTAssertTrue(workspace.configuration.profiles.contains(first))
        XCTAssertNotNil(workspace.error)
        left.saving = true
        XCTAssertTrue(workspace.saving)
        XCTAssertFalse(right.saving)
        left.saving = false
        workspace.shutdown()
        XCTAssertFalse(left.connectionEstablished)
        XCTAssertFalse(right.connectionEstablished)
    }
}
