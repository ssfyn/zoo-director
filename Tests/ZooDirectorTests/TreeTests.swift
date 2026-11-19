import XCTest
@testable import ZooDirector

/// 记录请求路径，以验证树不会隐式递归读取。
actor TreeRecordingService: ZooKeeperService {
    /// 提供固定层级的演示服务。
    private let demo = DemoService()
    /// 读取过直接子节点的目录。
    private(set) var requestedChildren: [String] = []
    /// 读取过状态的节点。
    private(set) var requestedStats: [String] = []
    /// 是否延迟响应，用于模拟切换上下文时仍未完成的请求。
    let delayed: Bool

    /// 初始化可选的响应延迟。
    init(delayed: Bool = false) { self.delayed = delayed }

    /// 记录名称请求，并按需模拟网络延迟。
    func children(_ path: String) async throws -> [String] {
        requestedChildren.append(path)
        if delayed { try await Task.sleep(for: .milliseconds(30)) }
        return try await demo.children(path)
    }

    /// 记录状态请求，返回不含节点内容的元信息。
    func stat(_ path: String) async throws -> NodeStat {
        requestedStats.append(path)
        if delayed { try await Task.sleep(for: .milliseconds(30)) }
        return try await demo.stat(path)
    }

    /// 代理读取数据，树展示不应调用此方法。
    func read(_ path: String) async throws -> NodeSnapshot { try await demo.read(path) }

    /// 代理带版本的演示写入。
    func write(_ path: String, data: Data, version: Int32) async throws {
        try await demo.write(path, data: data, version: version)
    }

    /// 演示服务不需要关闭网络连接。
    func close() {}
}

/// 对按需展开、资源边界与异步上下文隔离进行验证。
@MainActor
final class TreeTests: XCTestCase {
    /// 等待树的当前批次完成，同时让出主线程供异步结果更新。
    private func waitUntilIdle(_ tree: NodeTreeModel) async throws {
        for _ in 0..<200 {
            if !tree.loading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("树加载未在预期时间内完成")
    }

    /// 初始化不递归扫描，只有手动展开才读取该目录，折叠隐藏后代。
    func testLazyExpansionAndCollapse() async throws {
        let service = TreeRecordingService()
        let tree = NodeTreeModel()
        tree.reset(directory: "/services", names: ["api", "discovery", "workers"], service: service)
        try await waitUntilIdle(tree)
        let initialRequests = await service.requestedChildren
        XCTAssertTrue(initialRequests.isEmpty)
        XCTAssertEqual(tree.rows.count, 4)
        tree.toggle("/services/api")
        try await waitUntilIdle(tree)
        let expandedRequests = await service.requestedChildren
        XCTAssertEqual(expandedRequests, ["/services/api"])
        XCTAssertEqual(tree.rows.count, 7)
        XCTAssertTrue(tree.rows.contains { $0.id == "/services/api/instance-001" && $0.depth == 1 })
        tree.toggle("/services/api")
        XCTAssertEqual(tree.rows.count, 4)
        tree.toggle("/services/api")
        try await waitUntilIdle(tree)
        let reopenedRequests = await service.requestedChildren
        XCTAssertEqual(reopenedRequests.count, 1, "再次展开应复用当前上下文的名称缓存")
        tree.stop()
    }

    /// 二万个同级节点完整可访问，但只为实际显示的行读取状态。
    func testLargeBranchWithoutPagination() async throws {
        let service = TreeRecordingService()
        let names = (0..<20_000).map { String(format: "node-%05d", $0) }
        let tree = NodeTreeModel()
        tree.reset(directory: "/stress-test", names: names, service: service)
        try await waitUntilIdle(tree)
        XCTAssertEqual(tree.rows.count, 20_001)
        XCTAssertEqual(tree.rows.last?.id, "/stress-test/node-19999")
        let beforeDisplay = await service.requestedStats
        XCTAssertTrue(beforeDisplay.isEmpty)
        tree.requestMetadata("/stress-test/..")
        for row in tree.rows.filter({ $0.node.navigationTarget == nil }).prefix(25) { tree.requestMetadata(row.id) }
        try await waitUntilIdle(tree)
        let visibleStats = await service.requestedStats
        XCTAssertEqual(visibleStats.count, 25)
        XCTAssertFalse(visibleStats.contains("/stress-test/.."))
        XCTAssertFalse(visibleStats.contains("/stress-test/node-19999"))
        tree.stop()
    }

    /// 全局根目录不添加返回入口，也不重复展示根节点自身。
    func testGlobalRootHasOnlyChildren() async throws {
        let tree = NodeTreeModel()
        tree.reset(directory: "/", names: ["services", "configuration"], service: DemoService())
        try await waitUntilIdle(tree)
        XCTAssertEqual(tree.rows.map(\.id), ["/services", "/configuration"])
        XCTAssertTrue(tree.rows.allSatisfy { $0.depth == 0 && $0.node.navigationTarget == nil })
        tree.stop()
    }

    /// 进入目录不展示目录自身，切换上下文后旧任务不能覆盖新树。
    func testRootAndStaleResponses() async throws {
        let tree = NodeTreeModel()
        tree.reset(directory: "/services", names: ["api"], service: TreeRecordingService(delayed: true))
        tree.requestMetadata("/services/api")
        await Task.yield()
        tree.reset(directory: "/configuration/production", names: ["database"], service: DemoService())
        try await waitUntilIdle(tree)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tree.directory, "/configuration/production")
        XCTAssertEqual(tree.rows.map(\.id), ["/configuration/production/..", "/configuration/production/database"])
        XCTAssertTrue(tree.rows.allSatisfy { $0.id.hasPrefix("/configuration/production") })
        tree.stop()
    }
}

/// 验证默认树状浏览与搜索往返时不会截断节点。
@MainActor
final class TreeBrowsingTests: XCTestCase {
    /// 等待目录名称加载，失败时保留测试上下文。
    private func waitForDirectory(_ model: BrowserModel) async throws {
        for _ in 0..<300 {
            if !model.loading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("目录名称加载超时")
    }

    /// 等待检查器完成读取，避免把异步等待误判为没有节点内容。
    private func waitForInspector(_ model: BrowserModel) async throws {
        for _ in 0..<100 {
            if !model.reading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("检查器读取超时")
    }

    /// 默认展示完整节点树，搜索后清空关键词仍恢复完整树。
    func testCompleteTreeAndSearch() async throws {
        let model = BrowserModel(serviceFactory: { _ in DemoService() })
        model.connect(ConnectionProfile(name: "隔离演示测试", endpoint: UUID().uuidString, isDemo: true))
        try await waitForDirectory(model)
        model.navigate("/stress-test")
        try await waitForDirectory(model)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.showingTree)
        XCTAssertEqual(model.tree.rows.count, 20_001)
        XCTAssertEqual(model.tree.rows.last?.id, "/stress-test/node-19999")
        model.filter = "node-"
        model.updateSearchQuery()
        XCTAssertTrue(model.showingTree)
        XCTAssertEqual(model.tree.rows.count, 20_001)
        XCTAssertEqual(model.rows.count, 20_001)
        XCTAssertEqual(model.rows.last?.id, "/stress-test/node-19999")
        XCTAssertTrue(model.rows.allSatisfy { $0.stat == nil })
        model.requestMetadata("/stress-test/node-19999")
        for _ in 0..<100 {
            if model.rows.last?.stat != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(model.rows.last?.stat)
        XCTAssertNil(model.rows.first?.stat)
        model.filter = ""
        model.updateSearchQuery()
        try await waitForDirectory(model)
        XCTAssertEqual(model.tree.rows.count, 20_001)
        XCTAssertEqual(model.tree.rows.last?.id, "/stress-test/node-19999")
        XCTAssertEqual(model.tree.rows.first?.node.name, "..")
        XCTAssertFalse(model.tree.rows.contains { $0.id == "/stress-test" })
        model.select(model.tree.rows.first?.id)
        XCTAssertEqual(model.path, "/stress-test")
        try await waitForInspector(model)
        XCTAssertFalse(model.reading)
        XCTAssertEqual(model.inspectedPath, "/stress-test")
        XCTAssertNotNil(model.snapshot)
        model.navigate("/")
        try await waitForDirectory(model)
        XCTAssertEqual(model.path, "/")
        XCTAssertTrue(model.tree.rows.allSatisfy { $0.node.navigationTarget == nil })
        XCTAssertFalse(model.tree.rows.contains { $0.id == "/" })
        model.tree.stop()
    }

    /// 返回入口只被选中时不导航，打开入口仍沿用未保存保护。
    func testParentNavigationProtectsUnsavedData() async throws {
        let model = BrowserModel(serviceFactory: { _ in DemoService() })
        model.connect(ConnectionProfile(name: "隔离导航测试", endpoint: UUID().uuidString, isDemo: true))
        try await waitForDirectory(model)
        model.navigate("/services/api")
        try await waitForDirectory(model)
        let parent = try XCTUnwrap(model.tree.rows.first)
        XCTAssertEqual(parent.node.name, "..")
        XCTAssertEqual(parent.node.navigationTarget, "/services")
        model.select("/services/api/instance-001")
        for _ in 0..<100 {
            if !model.reading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(model.snapshot)
        model.editor += "\n"
        model.select(parent.id)
        XCTAssertEqual(model.path, "/services/api")
        XCTAssertNotNil(model.error)
        model.discard()
        model.error = nil
        model.select(parent.id)
        XCTAssertEqual(model.path, "/services/api")
        try await waitForInspector(model)
        XCTAssertFalse(model.reading)
        XCTAssertEqual(model.inspectedPath, "/services/api")
        XCTAssertNotNil(model.snapshot)
        model.navigate(try XCTUnwrap(parent.node.navigationTarget))
        try await waitForDirectory(model)
        XCTAssertEqual(model.path, "/services")
        XCTAssertNil(model.error)
        model.select(model.tree.rows.first?.id)
        XCTAssertEqual(model.path, "/services")
        model.navigate("/")
        try await waitForDirectory(model)
        XCTAssertEqual(model.path, "/")
        XCTAssertTrue(model.tree.rows.allSatisfy { $0.node.navigationTarget == nil })
        model.tree.stop()
    }

    /// 返回入口展示并编辑当前目录，不能读取或写入虚拟路径或上一级节点。
    func testParentInspectorReadsAndSavesCurrentDirectory() async throws {
        let model = BrowserModel(serviceFactory: { _ in DemoService() })
        model.connect(ConnectionProfile(name: "隔离检查器测试", endpoint: UUID().uuidString, isDemo: true))
        try await waitForDirectory(model)
        model.navigate("/services/api")
        try await waitForDirectory(model)
        let parent = try XCTUnwrap(model.tree.rows.first)
        model.select(parent.id)
        try await waitForInspector(model)
        XCTAssertEqual(model.selection, "/services/api/..")
        XCTAssertEqual(model.inspectedPath, "/services/api")
        XCTAssertEqual(model.path, "/services/api")
        let data = try XCTUnwrap(model.snapshot?.data)
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(content["path"] as? String, "/services/api")
        XCTAssertNil(model.error)
        model.editor = "current-directory-updated"
        model.save()
        for _ in 0..<100 {
            if !model.saving { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.saving)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.dirty)
        model.navigate("/services")
        try await waitForDirectory(model)
        model.select("/services/api")
        try await waitForInspector(model)
        XCTAssertEqual(model.editor, "current-directory-updated")
        XCTAssertEqual(model.inspectedPath, "/services/api")
        model.tree.stop()
    }
}
