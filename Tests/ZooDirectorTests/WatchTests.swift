import XCTest
@testable import ZooDirector

/// 可被测试中的另一个客户端修改的隔离服务，监听接口与真实连接一致。
actor MutableWatchService: ZooKeeperService {
    /// 当前存在的节点与原始数据。
    private var nodes: [String: Data] = ["/": Data(), "/services": Data(), "/services/api": Data("initial".utf8)]
    /// 各节点的数据版本。
    private var versions: [String: Int32] = [:]
    /// 使用正式的范围合并与广播实现。
    private let hub = WatchHub()
    /// 模拟已经安装到服务端的监听路径。
    private(set) var installed: Set<String> = []
    /// 目录读取次数，用于验证事件合并。
    private(set) var childReads: [String: Int] = [:]
    /// 内容读取次数，用于验证未编辑时自动更新。
    private(set) var dataReads = 0

    /// 返回当前目录的直接子节点，缺失路径按真实服务端语义返回错误。
    func children(_ path: String) throws -> [String] {
        childReads[path, default: 0] += 1
        guard nodes[path] != nil else { throw ZooKeeperError.server(-101) }
        return nodes.keys.filter { $0 != "/" && NodePath.parent(of: $0) == path }
            .map { String($0.split(separator: "/").last ?? "") }.sorted()
    }

    /// 根据当前数据计算真实的版本和直接子节点数。
    func stat(_ path: String) throws -> NodeStat {
        guard let data = nodes[path] else { throw ZooKeeperError.server(-101) }
        let count = nodes.keys.filter { $0 != "/" && NodePath.parent(of: $0) == path }.count
        return NodeStat(modified: Int64(versions[path, default: 0]), version: versions[path, default: 0],
                        dataLength: Int32(data.count), childCount: Int32(count))
    }

    /// 取得数据与版本，记录后台自动读取的次数。
    func read(_ path: String) throws -> NodeSnapshot {
        dataReads += 1
        guard let data = nodes[path] else { throw ZooKeeperError.server(-101) }
        return try NodeSnapshot(data: data, stat: stat(path))
    }

    /// 保留生产客户端的版本检查语义。
    func write(_ path: String, data: Data, version: Int32) async throws {
        guard nodes[path] != nil else { throw ZooKeeperError.server(-101) }
        guard versions[path, default: 0] == version else { throw ZooKeeperError.server(-103) }
        await put(path, text: String(decoding: data, as: UTF8.self))
    }

    /// 模拟外部客户端创建或修改节点，并发送对应通知。
    func put(_ path: String, text: String) async {
        let existed = nodes[path] != nil
        nodes[path] = Data(text.utf8)
        versions[path, default: 0] += 1
        await hub.receive(path: path, change: existed ? .data : .created)
        if !existed { await hub.receive(path: NodePath.parent(of: path), change: .children) }
    }

    /// 模拟删除节点，并通知其父目录和数据消费者。
    func remove(_ path: String) async {
        nodes.removeValue(forKey: path)
        await hub.receive(path: path, change: .deleted)
        await hub.receive(path: NodePath.parent(of: path), change: .children)
    }

    /// 提供独立的有界事件流。
    func watchEvents() async -> AsyncStream<WatchEvent> { await hub.events() }

    /// 使用正式管理器安装和移除范围，记录最终的服务端关注集合。
    func watch(_ paths: Set<String>, owner: UUID, revision: UInt64) async {
        await hub.update(paths: paths, owner: owner, revision: revision) { [weak self] path, enabled in
            await self?.record(path, enabled: enabled)
        }
    }

    /// 记录模拟的服务端监听范围变更。
    private func record(_ path: String, enabled: Bool) {
        if enabled { installed.insert(path) } else { installed.remove(path) }
    }

    /// 模拟连接断开，所有消费者必须获知实时更新已停止。
    func close() async { await hub.close("测试连接已断开") }
}

/// 验证实时浏览与后台刷新不会覆盖用户正在编辑的数据。
@MainActor
final class WatchTests: XCTestCase {
    /// 轮询明确的最终状态，并为异步事件合并留出有限时间。
    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("监听变化未在两秒内反映到预期状态")
    }

    /// 创建使用同一个可变服务的浏览模型，不连接任何真实业务环境。
    private func browser(_ service: MutableWatchService) async throws -> BrowserModel {
        let model = BrowserModel(serviceFactory: { _ in service })
        model.connect(ConnectionProfile(name: "监听隔离测试", endpoint: UUID().uuidString, isDemo: true))
        try await eventually { !model.loading && model.tree.rows.contains { $0.id == "/services" } }
        return model
    }

    /// 展开分支新增或删除节点时局部更新，其他分支和展开状态保持不变。
    func testExpandedBranchCreationDeletionAndCollapse() async throws {
        let service = MutableWatchService()
        let model = try await browser(service)
        model.tree.toggle("/services")
        try await eventually { model.tree.rows.contains { $0.id == "/services/api" } }
        try await eventually { await service.installed.contains("/services") }
        await service.put("/services/new", text: "created")
        try await eventually { model.tree.rows.contains { $0.id == "/services/new" } }
        XCTAssertTrue(model.tree.expanded.contains("/services"))
        await service.remove("/services/new")
        try await eventually { !model.tree.rows.contains { $0.id == "/services/new" } }
        model.tree.toggle("/services")
        try await eventually { !(await service.installed.contains("/services")) }
        let before = await service.childReads["/services", default: 0]
        await service.put("/services/later", text: "hidden")
        try await Task.sleep(for: .milliseconds(200))
        let after = await service.childReads["/services", default: 0]
        XCTAssertEqual(before, after)
        XCTAssertFalse(model.tree.rows.contains { $0.id == "/services/later" })
        model.tree.toggle("/services")
        try await eventually { model.tree.rows.contains { $0.id == "/services/later" } }
        model.tree.stop(); await service.close()
    }

    /// 当前层的变化更新计数和名称缓存，而不仅仅改变内层树表。
    func testCurrentDirectoryUpdatesNamesAndData() async throws {
        let service = MutableWatchService()
        let model = try await browser(service)
        await service.put("/another", text: "new")
        try await eventually { model.names.contains("/another") && model.tree.rows.contains { $0.id == "/another" } }
        model.navigate("/services")
        try await eventually { !model.loading && model.tree.rows.contains { $0.id == "/services/api" } }
        model.select("/services/api")
        try await eventually { model.editor == "initial" && !model.reading }
        try await eventually { await service.installed.contains("/services/api") }
        await service.put("/services/api", text: "external-first")
        try await eventually { model.editor == "external-first" }
        await service.put("/services/api", text: "external-second")
        try await eventually { model.editor == "external-second" }
        XCTAssertEqual(model.path, "/services")
        XCTAssertEqual(model.selection, "/services/api")
        model.tree.stop(); await service.close()
    }

    /// 数据已编辑时保留本地文字，放弃后重新读取服务端的最新内容。
    func testUnsavedEditorIsNeverOverwritten() async throws {
        let service = MutableWatchService()
        let model = try await browser(service)
        model.navigate("/services")
        try await eventually { !model.loading }
        model.select("/services/api")
        try await eventually { model.snapshot != nil && !model.reading }
        try await eventually { await service.installed.contains("/services/api") }
        model.editor = "local-unsaved"
        await service.put("/services/api", text: "remote-updated")
        try await eventually { model.inspectorNotice != nil }
        XCTAssertEqual(model.editor, "local-unsaved")
        XCTAssertTrue(model.dirty)
        model.discard()
        try await eventually { model.editor == "remote-updated" && !model.reading }
        XCTAssertFalse(model.dirty)
        XCTAssertNil(model.inspectorNotice)
        model.tree.stop(); await service.close()
    }

    /// 被选中的节点删除后提示失效，重建后自动恢复读取。
    func testDeletedInspectorRecoversAndDisconnectIsVisible() async throws {
        let service = MutableWatchService()
        let model = try await browser(service)
        model.navigate("/services")
        try await eventually { !model.loading }
        model.select("/services/api")
        try await eventually { model.snapshot != nil && !model.reading }
        try await eventually { await service.installed.contains("/services/api") }
        await service.remove("/services/api")
        try await eventually { model.inspectorNotice?.contains("deleted") == true }
        XCTAssertNil(model.snapshot)
        await service.put("/services/api", text: "recreated")
        try await eventually { model.editor == "recreated" && model.inspectorNotice == nil }
        await service.close()
        try await eventually { model.watchStatus.contains("stopped") }
        XCTAssertTrue(model.status.contains("Disconnected"))
        XCTAssertFalse(model.connectionEstablished)
        XCTAssertFalse(model.showingBrowser)
        model.tree.stop()
    }

    /// 一批连续变化应合并目录读取，不能每个事件都扫描目录。
    func testBurstIsCoalesced() async throws {
        let service = MutableWatchService()
        let model = try await browser(service)
        model.navigate("/services")
        try await eventually { !model.loading && model.watchStatus == "Live updates" }
        try await eventually { await service.installed.contains("/services") }
        try await Task.sleep(for: .milliseconds(200))
        let before = await service.childReads["/services", default: 0]
        for index in 0..<50 { await service.put("/services/burst-\(index)", text: "data") }
        try await eventually { model.tree.rows.contains { $0.id == "/services/burst-49" } }
        let after = await service.childReads["/services", default: 0]
        XCTAssertLessThanOrEqual(after - before, 3)
        XCTAssertEqual(model.tree.rows.filter { $0.node.name.hasPrefix("burst-") }.count, 50)
        model.tree.stop(); await service.close()
    }

    /// 事件消费者不能强持有浏览模型，窗口释放后必须结束相关任务。
    func testEventSubscriptionDoesNotRetainBrowser() async throws {
        let service = MutableWatchService()
        var model: BrowserModel? = try await browser(service)
        weak var observed = model
        try await eventually { await service.installed.contains("/") }
        model = nil
        try await eventually { observed == nil }
        XCTAssertNil(observed)
        await service.close()
    }
}
