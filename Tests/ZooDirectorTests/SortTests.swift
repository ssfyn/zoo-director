import XCTest
@testable import ZooDirector

/// 覆盖四种字段、缺失状态和导航入口的排序边界。
final class SortTests: XCTestCase {
    /// 数值字段按原始值排序，升降序都将状态缺失项置底。
    func testNumericFieldsAndMissingMetadata() throws {
        let low = NodeRow(id: "/z", name: "z", stat: NodeStat(created: 2, modified: 3, childCount: 2))
        let high = NodeRow(id: "/a", name: "a", stat: NodeStat(created: 10, modified: 20, childCount: 10))
        let missing = NodeRow(id: "/missing", name: "missing")
        let parent = try XCTUnwrap(NodeRow.parent(of: "/folder"))
        for key in ["created", "modified", "children"] {
            for ascending in [true, false] {
                let result = [missing, high, parent, low].sorted(by: NodeSort(key: key, ascending: ascending).precedes)
                XCTAssertEqual(result.map(\.id), [parent.id, ascending ? low.id : high.id,
                                                 ascending ? high.id : low.id, missing.id])
            }
        }
    }

    /// 名称自然排序使数字后缀符合阅读顺序，同名结果以完整路径打破平局。
    func testNaturalNamesAndStableTies() {
        let nodes = [NodeRow(id: "/b/node2", name: "node2"), NodeRow(id: "/node10", name: "node10"),
                     NodeRow(id: "/a/node2", name: "node2")]
        XCTAssertEqual(nodes.sorted(by: NodeSort(key: "name", ascending: true).precedes).map(\.id),
                       ["/a/node2", "/b/node2", "/node10"])
        XCTAssertEqual(nodes.sorted(by: NodeSort(key: "name", ascending: false).precedes).first?.id, "/node10")
    }
}

/// 验证排序需要的状态加载范围及树和列表的实际顺序。
@MainActor
final class SortingIntegrationTests: XCTestCase {
    /// 等待异步加载完成，超时时明确报告失败。
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("排序加载超时")
    }

    /// 数值排序读取全部同级状态但不扫描折叠分支，展开后仍保留父子相邻。
    func testTreeSortingAndMetadataScope() async throws {
        let service = TreeRecordingService()
        let tree = NodeTreeModel()
        tree.reset(directory: "/services", names: ["workers", "api", "discovery"], service: service)
        tree.setSort(NodeSort(key: "children", ascending: false))
        try await waitFor { !tree.loading }
        XCTAssertEqual(tree.rows.map(\.id), ["/services/..", "/services/api", "/services/workers", "/services/discovery"])
        let stats = await service.requestedStats
        let directories = await service.requestedChildren
        XCTAssertEqual(Set(stats), Set(["/services/api", "/services/discovery", "/services/workers"]))
        XCTAssertTrue(directories.isEmpty)
        tree.toggle("/services/api")
        try await waitFor { !tree.loading }
        XCTAssertEqual(tree.rows[2].id, "/services/api/instance-003")
        XCTAssertEqual(tree.rows[2].depth, 1)
        XCTAssertEqual(tree.rows[5].id, "/services/workers")
        tree.setSort(NodeSort(key: "name", ascending: true))
        try await waitFor { !tree.loading }
        XCTAssertEqual(tree.rows[2].id, "/services/api/instance-001")
        tree.stop()
    }

    /// 当前目录筛选保留树结构，补齐匹配分支的状态后按数值与名称排序。
    func testSearchListSorting() async throws {
        let suite = "ZooDirector.Sort.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BrowserModel(defaults: defaults, serviceFactory: { _ in DemoService() })
        model.connect(ConnectionProfile(name: "排序测试", endpoint: UUID().uuidString, isDemo: true))
        try await waitFor { !model.loading }
        model.navigate("/services")
        try await waitFor { !model.loading }
        model.filter = "i"
        model.updateSearchQuery()
        model.setNodeSort(NodeSort(key: "children", ascending: false))
        try await waitFor { model.tree.rows.dropFirst().allSatisfy { $0.node.stat != nil } }
        XCTAssertEqual(model.tree.rows.map { $0.node.name }, ["..", "api", "discovery"])
        model.setNodeSort(NodeSort(key: "name", ascending: false))
        XCTAssertEqual(model.tree.rows.map { $0.node.name }, ["..", "discovery", "api"])
        model.tree.stop()
    }
}
