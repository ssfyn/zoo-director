import XCTest
@testable import ZooDirector

/// 覆盖节点结构写入、删除预检和原生多选状态的边界行为。
@MainActor
final class MutationTests: XCTestCase {
    /// 等待浏览模型异步完成指定操作，超时明确失败。
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("节点操作未在四秒内完成")
    }

    /// 名称不能跨层级或使用导航入口，重叠删除只保留父目标。
    func testMutationPathValidation() throws {
        XCTAssertEqual(try NodeMutations.creationPath(parent: "/services", name: "新节点"), "/services/新节点")
        for name in ["", ".", "..", "a/b", "bad\u{0}"] {
            XCTAssertThrowsError(try NodeMutations.creationPath(parent: "/", name: name))
        }
        XCTAssertThrowsError(try NodeMutations.deletionRoots(["/"]))
        XCTAssertEqual(try NodeMutations.deletionRoots(["/a", "/a/b", "/a-b", "/z"]), ["/a", "/a-b", "/z"])
    }

    /// 非递归批量预检失败时不会先删除其他目标，递归删除不会触及兄弟节点。
    func testDeletionPreflightAndOverlappingRoots() async throws {
        let service = DemoService()
        try await service.create("/batch", data: Data(), ephemeral: false)
        try await service.create("/batch/child", data: Data("payload".utf8), ephemeral: false)
        try await service.create("/sibling", data: Data(), ephemeral: false)
        do {
            _ = try await NodeMutations.delete(paths: ["/sibling", "/batch"], recursive: false, service: service)
            XCTFail("非空目标必须在预检阶段拒绝")
        } catch { XCTAssertTrue(error.localizedDescription.contains("尚未删除")) }
        _ = try await service.stat("/sibling")
        let roots = try NodeMutations.deletionRoots(["/batch", "/batch/child"])
        let count = try await NodeMutations.delete(paths: roots, recursive: true, service: service)
        XCTAssertEqual(count, 2)
        let names = try await service.children("/")
        XCTAssertFalse(names.contains("batch"))
        XCTAssertTrue(names.contains("sibling"))
        do { _ = try await service.read("/batch/child"); XCTFail("删除后不能继续读取") } catch {}
    }

    /// 创建内容、临时类型、重复名称及删除版本冲突均保持服务端语义。
    func testCreateAndVersionProtection() async throws {
        let service = DemoService()
        try await service.create("/temporary", data: Data("value".utf8), ephemeral: true)
        let value = try await service.read("/temporary")
        XCTAssertTrue(value.stat.isEphemeral)
        XCTAssertEqual(value.data, Data("value".utf8))
        do { try await service.create("/temporary", data: Data(), ephemeral: false); XCTFail("重复名称必须失败") } catch {}
        do { try await service.create("/temporary/child", data: Data(), ephemeral: false); XCTFail("临时节点不能有子节点") } catch {}
        try await service.write("/temporary", data: Data(), version: value.stat.version)
        do { try await service.delete("/temporary", version: value.stat.version); XCTFail("旧版本删除必须失败") } catch {}
        let latest = try await service.stat("/temporary")
        try await service.delete("/temporary", version: latest.version)
        try await service.create("/temporary", data: Data(), ephemeral: false)
        let recreated = try await service.stat("/temporary")
        XCTAssertFalse(recreated.isEphemeral)
    }

    /// 多选保留检查器焦点，未保存内容阻止批量删除及选择变化。
    func testBrowserMultiSelectionAndMutationRefresh() async throws {
        let service = DemoService()
        let model = BrowserModel(serviceFactory: { _ in service })
        model.connect(ConnectionProfile(name: "结构测试", endpoint: "demo", isDemo: true))
        try await eventually { !model.loading }
        let created = await model.createNode(parent: "/", name: "new-node", text: "initial", ephemeral: false)
        XCTAssertTrue(created)
        try await eventually { model.tree.rows.contains { $0.id == "/new-node" } }
        model.selectMany(["/new-node", "/zookeeper"], primary: "/new-node")
        try await eventually { !model.reading }
        XCTAssertEqual(model.selectedPaths.count, 2)
        model.editor = "unsaved"
        model.beginDeletingNodes()
        XCTAssertTrue(model.deletionTargets.isEmpty)
        model.selectMany(["/services"], primary: "/services")
        XCTAssertEqual(model.selectedPaths.count, 2)
        model.discard()
        model.beginDeletingNodes()
        XCTAssertEqual(model.deletionTargets, ["/new-node", "/zookeeper"])
        await model.deleteNodes(recursive: false)
        try await eventually { !model.tree.rows.contains { $0.id == "/new-node" || $0.id == "/zookeeper" } }
        XCTAssertTrue(model.selectedPaths.isEmpty)
        XCTAssertNil(model.snapshot)
        model.navigate("/services")
        try await eventually { !model.loading }
        model.select(NodeRow.parent(of: "/services")?.id)
        XCTAssertTrue(model.deletableSelection.isEmpty)
    }

    /// 在显式配置的隔离实例中验证正式客户端创建和多节点删除协议。
    func testLiveClientMutations() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ZOODIRECTOR_TEST_ENDPOINT"] else {
            throw XCTSkip("设置隔离的 ZOODIRECTOR_TEST_ENDPOINT 后验证真实节点写入")
        }
        let client = try ZooKeeperClient(endpoint: endpoint)
        try await client.connect()
        let base = "/zoodirector-mutations-" + UUID().uuidString
        do {
            try await client.create(base, data: Data(), ephemeral: false)
            try await client.create(base + "/a", data: Data("hello".utf8), ephemeral: false)
            try await client.create(base + "/b", data: Data(), ephemeral: true)
            let value = try await client.read(base + "/a")
            XCTAssertEqual(value.data, Data("hello".utf8))
            let temp = try await client.stat(base + "/b")
            XCTAssertTrue(temp.isEphemeral)
            let count = try await NodeMutations.delete(paths: [base + "/a", base + "/b"], recursive: false, service: client)
            XCTAssertEqual(count, 2)
            let children = try await client.children(base)
            XCTAssertTrue(children.isEmpty)
            _ = try await NodeMutations.delete(paths: [base], recursive: false, service: client)
            await client.close()
        } catch {
            _ = try? await NodeMutations.delete(paths: [base], recursive: true, service: client)
            await client.close()
            throw error
        }
    }
}
