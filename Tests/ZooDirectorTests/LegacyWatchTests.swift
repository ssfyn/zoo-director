import XCTest
@testable import ZooDirector

/// 验证能力未知或服务端较旧时，绝不能通过新操作码试探主连接。
@MainActor
final class LegacyWatchTests: XCTestCase {
    /// 版本识别只允许明确支持的版本使用持久监听。
    func testSafeCapabilityDetection() {
        XCTAssertEqual(ZooKeeperWatchMode.parse(serverInfo: "Zookeeper version: 3.4.12-e5259e"), .standard)
        XCTAssertEqual(ZooKeeperWatchMode.parse(serverInfo: "Zookeeper version: 3.5.10-build"), .standard)
        XCTAssertEqual(ZooKeeperWatchMode.parse(serverInfo: "srvr is not executed because it is not in the whitelist."), .standard)
        XCTAssertEqual(ZooKeeperWatchMode.parse(serverInfo: ""), .standard)
        XCTAssertEqual(ZooKeeperWatchMode.parse(serverInfo: "Zookeeper version: 3.6.0-build"), .persistent)
        XCTAssertEqual(ZooKeeperWatchMode.parse(serverInfo: "Zookeeper version: 3.8.8-build"), .persistent)
        XCTAssertEqual(ZooKeeperWatchMode.parse(serverInfo: "Zookeeper version: 3.10.0-build"), .persistent)
    }

    /// 对显式指定的旧实例只做读取与监听，跨越心跳及原有读超时窗口验证连接稳定。
    func testLegacyServerReadOnlyConnectionStaysAlive() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ZOODIRECTOR_LEGACY_TEST_ENDPOINT"] else {
            throw XCTSkip("设置 ZOODIRECTOR_LEGACY_TEST_ENDPOINT 可进行旧服务端只读验证")
        }
        let client = try ZooKeeperClient(endpoint: endpoint)
        let events = WatchEventLog()
        try await client.connect()
        let mode = await client.watchMode
        XCTAssertEqual(mode, .standard)
        let stream = await client.watchEvents()
        let consumer = Task { for await event in stream { await events.append(event) } }
        let owner = UUID()
        do {
            _ = try await client.children("/")
            await client.watch(["/"], owner: owner, revision: 1)
            for _ in 0..<200 {
                if await events.synchronized("/") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let registered = await events.synchronized("/")
            XCTAssertTrue(registered, "兼容监听应在旧服务端注册成功")
            for _ in 0..<4 {
                try await Task.sleep(for: .seconds(5))
                _ = try await client.stat("/")
            }
            await client.watch([], owner: owner, revision: 2)
            _ = try await client.children("/")
            let received = await events.events
            XCTAssertFalse(received.contains {
                if case .disconnected = $0 { return true }
                if case .unavailable = $0 { return true }
                return false
            })
            await client.close()
            await consumer.value
        } catch {
            await client.close()
            await consumer.value
            throw error
        }
    }
}
