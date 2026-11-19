import XCTest
@testable import ZooDirector

/// 安装操作的隔离日志，供监听去重与移除验证。
actor WatchOperationLog {
    /// 按执行顺序记录的路径与启用标记。
    private(set) var operations: [(String, Bool)] = []
    /// 追加一次服务端模拟操作。
    func append(_ path: String, _ enabled: Bool) { operations.append((path, enabled)) }
}

/// 记录异步通知，不依赖界面框架。
actor WatchEventLog {
    /// 已收到的完整事件序列。
    private(set) var events: [WatchEvent] = []
    /// 追加一条监听事件。
    func append(_ event: WatchEvent) { events.append(event) }
    /// 判断指定路径是否完成过监听安装。
    func synchronized(_ path: String) -> Bool {
        events.contains { if case .resync(let target) = $0 { return target == path }; return false }
    }
    /// 判断是否已经提示能力不兼容。
    func unsupported() -> Bool {
        events.contains { if case .unavailable(let text) = $0 { return text.contains("3.6") }; return false }
    }
}

/// 验证多个界面关注者的引用合并与错误降级。
@MainActor
final class WatchHubTests: XCTestCase {
    /// 在有限时间内等待跨执行器的最终状态。
    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("监听管理器未达到预期状态")
    }

    /// 多个消费者共用一次注册，最后一个离开时移除，迟到范围不能复活旧监听。
    func testOwnersShareWatchAndRejectStaleRevision() async throws {
        let hub = WatchHub()
        let log = WatchOperationLog()
        let ownerA = UUID(), ownerB = UUID()
        let operation: @Sendable (String, Bool) async throws -> Void = { path, enabled in await log.append(path, enabled) }
        await hub.update(paths: ["/services"], owner: ownerA, revision: 1, change: operation)
        try await eventually { await log.operations.count == 1 }
        await hub.update(paths: ["/services"], owner: ownerB, revision: 1, change: operation)
        await hub.update(paths: [], owner: ownerA, revision: 2, change: operation)
        try await Task.sleep(for: .milliseconds(30))
        let shared = await log.operations
        XCTAssertEqual(shared.count, 1)
        await hub.update(paths: [], owner: ownerB, revision: 2, change: operation)
        try await eventually { await log.operations.count == 2 }
        await hub.update(paths: ["/services"], owner: ownerB, revision: 1, change: operation)
        try await Task.sleep(for: .milliseconds(30))
        let final = await log.operations
        XCTAssertEqual(final.count, 2)
        XCTAssertTrue(final[0].1)
        XCTAssertFalse(final[1].1)
        await hub.close("测试完成")
    }

    /// 老服务端不支持持久协议时只提示一次，不对每个可见节点重复失败注册。
    func testUnsupportedServerStopsRegistrationLoop() async throws {
        let hub = WatchHub()
        let operations = WatchOperationLog()
        let events = WatchEventLog()
        let stream = await hub.events()
        let consumer = Task { for await event in stream { await events.append(event) } }
        await hub.update(paths: ["/a", "/b", "/c"], owner: UUID(), revision: 1) { path, enabled in
            await operations.append(path, enabled)
            throw ZooKeeperError.server(-6)
        }
        try await eventually { await events.unsupported() }
        let recorded = await operations.operations
        XCTAssertEqual(recorded.count, 1)
        await hub.close("测试完成")
        await consumer.value
    }

    /// 队列溢出必须发出完整重同步通知，避免界面永久保留丢失事件之前的数据。
    func testOverflowRequestsResynchronization() async throws {
        let hub = WatchHub()
        let log = WatchOperationLog()
        let stream = await hub.events()
        await hub.update(paths: ["/a"], owner: UUID(), revision: 1) { path, enabled in await log.append(path, enabled) }
        try await eventually { await log.operations.count == 1 }
        for _ in 0..<1_100 { await hub.receive(path: "/a", change: .data) }
        await hub.close("测试完成")
        var receivedResync = false
        for await event in stream { if case .resync(nil) = event { receivedResync = true } }
        XCTAssertTrue(receivedResync)
    }
}
