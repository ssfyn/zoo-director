import XCTest
@testable import ZooDirector

/// 搜索框失焦重复提交不能重置选择、搜索结果或检查器。
@MainActor
final class SearchSelectionTests: XCTestCase {
    /// 等待目录或检查器异步完成，失败时明确报告超时。
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("搜索或节点读取未在四秒内完成")
    }

    /// 创建独立演示服务，避免测试读写实际连接或依赖用户配置。
    private func connectedModel() async throws -> BrowserModel {
        let model = BrowserModel(serviceFactory: { _ in DemoService() })
        model.connect(ConnectionProfile(name: "搜索选择测试", endpoint: "demo"))
        try await eventually { model.connectionEstablished && !model.loading }
        return model
    }

    /// 当前层搜索结束编辑时保留相同的行结构，第一次选择立即生效。
    func testCurrentSearchRepeatedCommitPreservesFirstSelection() async throws {
        let model = try await connectedModel()
        defer { model.disconnect() }
        model.setSearchQuery("service")
        XCTAssertEqual(model.rows.map(\.id), ["/services"])
        let revision = model.rowsRevision
        model.setSearchQuery("service")
        XCTAssertEqual(model.rowsRevision, revision)
        model.selectMany(["/services"], primary: "/services")
        model.setSearchQuery("service")
        try await eventually { !model.reading }
        XCTAssertEqual(model.rowsRevision, revision)
        XCTAssertEqual(model.selection, "/services")
        XCTAssertEqual(model.selectedPaths, ["/services"])
        XCTAssertNotNil(model.snapshot)
    }

    /// 递归结果完成后重复提交原文，不清空结果、完成提示或多选状态。
    func testDescendantSearchRepeatedCommitPreservesResults() async throws {
        let model = try await connectedModel()
        defer { model.disconnect() }
        model.navigate("/services")
        try await eventually { !model.loading }
        model.searchScope = .descendants
        model.setSearchQuery("instance")
        model.search()
        try await eventually { !model.searching && model.names.count == 3 }
        let results = model.rows.map(\.id)
        let revision = model.rowsRevision
        let summary = model.searchSummary
        model.setSearchQuery("instance")
        let target = try XCTUnwrap(model.names.first)
        model.selectMany([target], primary: target)
        model.setSearchQuery("instance")
        try await eventually { !model.reading }
        XCTAssertEqual(model.rows.map(\.id), results)
        XCTAssertEqual(model.rowsRevision, revision)
        XCTAssertEqual(model.searchSummary, summary)
        XCTAssertEqual(model.selection, target)
        XCTAssertNotNil(model.snapshot)
        model.setSearchQuery("workers")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.searchSummary?.contains("press Return to begin") == true)
    }

    /// 当前层只筛选起点名称，展开后显示完整后代，改词及清空保留原展开缓存。
    func testCurrentSearchKeepsExpandableBranchesAndCache() async throws {
        let service = TreeRecordingService()
        let model = BrowserModel(serviceFactory: { _ in service })
        model.connect(ConnectionProfile(name: "筛选树测试", endpoint: "demo"))
        defer { model.disconnect() }
        try await eventually { model.connectionEstablished && !model.loading }
        model.navigate("/services")
        try await eventually { !model.loading }
        model.setSearchQuery("API")
        XCTAssertTrue(model.showingTree)
        XCTAssertEqual(model.tree.rows.map(\.id), ["/services/..", "/services/api"])
        XCTAssertTrue(model.tree.rows.last?.expandable == true)
        let before = await service.requestedChildren
        model.tree.toggle("/services/api")
        try await eventually { model.tree.rows.contains { $0.id == "/services/api/instance-001" } }
        XCTAssertEqual(model.tree.rows.count, 5)
        XCTAssertTrue(model.tree.rows.dropFirst(2).allSatisfy { $0.depth == 1 })
        model.setSearchQuery("worker")
        XCTAssertEqual(model.tree.rows.map(\.id), ["/services/..", "/services/workers"])
        model.setSearchQuery("")
        XCTAssertTrue(model.tree.rows.contains { $0.id == "/services/api/instance-001" })
        XCTAssertTrue(model.tree.expanded.contains("/services/api"))
        model.setSearchQuery("api")
        model.select("/services/api")
        try await eventually { !model.reading }
        let revision = model.tree.revision
        model.setSearchQuery("api")
        XCTAssertEqual(model.tree.revision, revision)
        XCTAssertEqual(model.selection, "/services/api")
        model.tree.toggle("/services/api")
        XCTAssertEqual(model.tree.rows.count, 2)
        model.tree.toggle("/services/api")
        try await eventually { !model.tree.loading }
        let after = await service.requestedChildren
        XCTAssertEqual(after.count, before.count + 1, "本地筛选和再次展开均不重新读取目录")
    }

    /// 筛选树仍监听当前目录和展开分支，新匹配项及子节点能实时更新。
    func testFilteredTreeReceivesDirectoryAndBranchChanges() async throws {
        let service = MutableWatchService()
        let model = BrowserModel(serviceFactory: { _ in service })
        model.connect(ConnectionProfile(name: "筛选监听测试", endpoint: "demo"))
        defer { model.disconnect() }
        try await eventually { model.connectionEstablished && !model.loading }
        model.setSearchQuery("service")
        try await eventually { await service.installed.contains("/") }
        await service.put("/services-extra", text: "")
        await service.put("/other", text: "")
        try await eventually { model.tree.rows.contains { $0.id == "/services-extra" } }
        XCTAssertFalse(model.tree.rows.contains { $0.id == "/other" })
        model.tree.toggle("/services")
        try await eventually { await service.installed.contains("/services") }
        await service.put("/services/new-child", text: "")
        try await eventually { model.tree.rows.contains { $0.id == "/services/new-child" } }
        XCTAssertTrue(model.tree.expanded.contains("/services"))
        model.setSearchQuery("")
        XCTAssertTrue(model.tree.rows.contains { $0.id == "/other" })
    }

    /// 相同文本提交不干扰尚未保存的编辑，真正修改关键词仍遵循编辑保护。
    func testRepeatedQueryPreservesUnsavedInspector() async throws {
        let model = try await connectedModel()
        model.setSearchQuery("service")
        model.select("/services")
        try await eventually { !model.reading }
        model.editor = "未保存的内容"
        model.setSearchQuery("service")
        XCTAssertTrue(model.dirty)
        XCTAssertNil(model.error)
        model.setSearchQuery("config")
        XCTAssertEqual(model.filter, "service")
        XCTAssertEqual(model.selection, "/services")
        XCTAssertNotNil(model.error)
        model.discard()
        model.disconnect()
    }
}
