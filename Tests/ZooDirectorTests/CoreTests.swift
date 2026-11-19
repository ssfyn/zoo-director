import XCTest
@testable import ZooDirector

/// 协议和路径的边界验证，防止错误响应导致越界或覆盖数据。
final class CoreTests: XCTestCase {
    /// 检查大端序、负数、空数据与多字节文本的往返编码。
    func testJuteRoundTrip() throws {
        var writer = JuteWriter()
        writer.integer(Int32(-103))
        writer.integer(Int64.max)
        writer.string("节点/配置")
        writer.buffer(Data())
        var reader = JuteReader(data: writer.data)
        XCTAssertEqual(try reader.integer(Int32.self), -103)
        XCTAssertEqual(try reader.integer(Int64.self), .max)
        XCTAssertEqual(try reader.string(), "节点/配置")
        XCTAssertEqual(try reader.buffer(), Data())
    }

    /// 损坏的数据长度和截断整数必须返回错误。
    func testMalformedPackets() {
        var empty = JuteReader(data: Data([0, 1]))
        XCTAssertThrowsError(try empty.integer(Int32.self))
        var length = JuteWriter()
        length.integer(Int32.max)
        var invalid = JuteReader(data: length.data)
        XCTAssertThrowsError(try invalid.buffer())
        var negative = JuteWriter()
        negative.integer(Int32(-2))
        var invalidNegative = JuteReader(data: negative.data)
        XCTAssertThrowsError(try invalidNegative.buffer())
    }

    /// 验证路径边界与根节点拼接。
    func testPaths() throws {
        for path in ["", "relative", "/a/", "/a//b", "/a/../b", "/a/./b", "/a\u{0000}"] {
            XCTAssertThrowsError(try NodePath.validate(path), path)
        }
        XCTAssertEqual(try NodePath.validate("/服务/应用"), "/服务/应用")
        XCTAssertEqual(NodePath.child("api", of: "/"), "/api")
        XCTAssertEqual(NodePath.parent(of: "/a"), "/")
        XCTAssertEqual(NodePath.parent(of: "/"), "/")
    }

    /// 验证二万节点样本和并发修改的版本冲突。
    func testDemoScaleAndVersionConflict() async throws {
        let demo = DemoService()
        let names = try await demo.children("/stress-test")
        XCTAssertEqual(names.count, 20_000)
        let value = try await demo.read("/services")
        try await demo.write("/services", data: Data("updated".utf8), version: value.stat.version)
        do {
            try await demo.write("/services", data: Data(), version: value.stat.version)
            XCTFail("旧版本写入必须失败")
        } catch { XCTAssertTrue(error.localizedDescription.contains("修改")) }
        let changed = try await demo.read("/services")
        XCTAssertEqual(String(data: changed.data, encoding: .utf8), "updated")
    }

    /// 拒绝当前尚不支持的连接串，避免错误连接至意外服务器。
    func testEndpointValidation() throws {
        for endpoint in ["localhost", "host:0", "host:65536", "a:2181,b:2181", "host:2181/root", "user@host:2181"] {
            XCTAssertThrowsError(try ZooKeeperTransport(endpoint: endpoint), endpoint)
        }
        _ = try ZooKeeperTransport(endpoint: "localhost:2181")
        _ = try ZooKeeperTransport(endpoint: "[::1]:2181")
    }

    /// 递归搜索必须限制在传入路径内，不能扫描兄弟目录或全局根。
    func testSearchScopeAndLimits() async throws {
        let demo = DemoService()
        let result = try await NodeSearch.run(root: "/services", query: "instance", service: demo)
        XCTAssertEqual(result.paths.count, 3)
        XCTAssertTrue(result.paths.allSatisfy { $0.hasPrefix("/services/api/") })
        XCTAssertFalse(result.limited)
        let outside = try await NodeSearch.run(root: "/configuration", query: "instance", service: demo)
        XCTAssertTrue(outside.paths.isEmpty)
        let limited = try await NodeSearch.run(root: "/stress-test", query: "node", service: demo, resultLimit: 20)
        XCTAssertEqual(limited.paths.count, 20)
        XCTAssertTrue(limited.limited)
    }

    /// 已取消的搜索必须及时结束，不能继续遍历服务端。
    func testSearchCancellation() async throws {
        let task = Task {
            try Task.checkCancellation()
            return try await NodeSearch.run(root: "/stress-test", query: "missing", service: DemoService())
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("搜索应响应取消") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    /// 仅在显式提供隔离测试服务时执行真实 TCP 读写验证。
    func testLiveConnection() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ZOODIRECTOR_TEST_ENDPOINT"] else {
            throw XCTSkip("设置 ZOODIRECTOR_TEST_ENDPOINT 可运行隔离服务集成测试")
        }
        let client = try ZooKeeperClient(endpoint: endpoint)
        try await client.connect()
        do {
            let children = try await client.children("/")
            XCTAssertTrue(children.contains("zookeeper"))
            let stat = try await client.stat("/zoodirector-test")
            let snapshot = try await client.read("/zoodirector-test")
            XCTAssertEqual(stat.version, snapshot.stat.version)
            try await client.write("/zoodirector-test", data: Data("integration-ok".utf8), version: snapshot.stat.version)
            let updated = try await client.read("/zoodirector-test")
            XCTAssertEqual(String(data: updated.data, encoding: .utf8), "integration-ok")
            do {
                try await client.write("/zoodirector-test", data: Data(), version: snapshot.stat.version)
                XCTFail("真实服务应拒绝过期版本")
            } catch { XCTAssertTrue(error.localizedDescription.contains("修改")) }
            await client.close()
        } catch {
            await client.close()
            throw error
        }
    }
}
