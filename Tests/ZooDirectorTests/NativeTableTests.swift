import AppKit
import XCTest
@testable import ZooDirector

/// 验证全量目录在原生滚动容器中的视口范围与行复用。
@MainActor
final class NativeTableTests: XCTestCase {
    /// 复用单元格时清除旧标识，未加载状态和导航行不能显示临时标签。
    func testEphemeralBadgeReuse() throws {
        let cell = NodeNameCell()
        let content = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSStackView }.first)
        let badge = try XCTUnwrap(content.arrangedSubviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "临时" })
        let temporary = NodeRow(id: "/instance", name: "instance", stat: NodeStat(ephemeralOwner: 42))
        cell.configure(node: temporary, tree: nil, blocked: false, onToggle: {})
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual(cell.textField?.stringValue, "instance")
        let regular = NodeRow(id: "/config", name: "config", stat: NodeStat())
        cell.configure(node: regular, tree: nil, blocked: false, onToggle: {})
        XCTAssertTrue(badge.isHidden)
        cell.configure(node: temporary, tree: nil, blocked: false, onToggle: {})
        cell.configure(node: NodeRow(id: "/pending", name: "pending"), tree: nil, blocked: false, onToggle: {})
        XCTAssertTrue(badge.isHidden)
        cell.configure(node: temporary, tree: nil, blocked: false, onToggle: {})
        var parent = try XCTUnwrap(NodeRow.parent(of: "/services"))
        parent.stat = temporary.stat
        cell.configure(node: parent, tree: nil, blocked: false, onToggle: {})
        XCTAssertTrue(badge.isHidden)
    }

    /// 递归结果展示相对上级路径，复用回普通树和导航行时恢复名称与截断规则。
    func testRecursiveSearchShowsParentPathsAndResetsReusedCell() {
        let model = BrowserModel()
        model.searchScope = .descendants
        model.path = "/services"
        let nodes = ["/services/production/config", "/services/staging/config"].map {
            NodeRow(id: $0, name: "config")
        }
        let source = NativeNodeTable(model: model, nodes: nodes, treeRows: [], treeMode: false,
                                     revision: UUID(), selectedPath: nil, blocked: false)
        let coordinator = source.makeCoordinator()
        let table = NodeTable()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        let first = coordinator.tableView(table, viewFor: column, row: 0) as? NodeNameCell
        let second = coordinator.tableView(table, viewFor: column, row: 1) as? NodeNameCell
        XCTAssertEqual(first?.textField?.stringValue, "./production/config")
        XCTAssertEqual(second?.textField?.stringValue, "./staging/config")
        XCTAssertEqual(first?.textField?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(first?.toolTip, nodes[0].id)
        first?.configure(node: nodes[0], tree: nil, blocked: false, showPath: true, relativeTo: "/", onToggle: {})
        XCTAssertEqual(first?.textField?.stringValue, "./services/production/config")
        first?.configure(node: NodeRow(id: "/services/config", name: "config"), tree: nil,
                         blocked: false, showPath: true, relativeTo: "/services", onToggle: {})
        XCTAssertEqual(first?.textField?.stringValue, "./config")
        first?.configure(node: nodes[0], tree: nil, blocked: false, onToggle: {})
        XCTAssertEqual(first?.textField?.stringValue, "config")
        XCTAssertEqual(first?.textField?.lineBreakMode, .byTruncatingTail)
        if let parent = NodeRow.parent(of: "/services") {
            first?.configure(node: parent, tree: nil, blocked: false, showPath: true, onToggle: {})
            XCTAssertEqual(first?.textField?.stringValue, "..")
        }
        coordinator.stop()
    }

    /// 右键菜单对目标节点切换收藏状态，不跳转目录或产生重复收藏。
    func testContextFavoriteToggle() async throws {
        let suite = "ZooDirector.ContextFavorites.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BrowserModel(defaults: defaults, serviceFactory: { _ in DemoService() })
        if model.profiles.isEmpty { model.addConnection(name: "隔离测试", endpoint: "localhost:2181") }
        model.connect(try XCTUnwrap(model.profiles.first))
        for _ in 0..<200 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.loading)
        let source = NativeNodeTable(model: model, nodes: [NodeRow(id: "/services", name: "services")],
                                     treeRows: [], treeMode: false, revision: UUID(), selectedPath: "/services", blocked: false)
        let coordinator = source.makeCoordinator()
        let table = NodeTable()
        table.dataSource = coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        coordinator.attach(table: table, scroll: scroll)
        coordinator.update(source)
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        let add = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(add.title, "收藏")
        _ = coordinator.perform(try XCTUnwrap(add.action))
        XCTAssertEqual(model.favorites, ["/services"])
        XCTAssertEqual(model.path, "/")
        model.addFavorite("/services")
        XCTAssertEqual(model.favorites, ["/services"])
        coordinator.menuNeedsUpdate(menu)
        let remove = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(remove.title, "移除收藏")
        _ = coordinator.perform(try XCTUnwrap(remove.action))
        XCTAssertTrue(model.favorites.isEmpty)
        coordinator.stop()
        model.tree.stop()
    }

    /// 多选高亮在排序重建后按路径恢复，不因行号变化误删其他节点。
    func testMultipleSelectionSurvivesRowReorder() {
        let model = BrowserModel()
        let nodes = ["a", "b", "c"].map { NodeRow(id: "/" + $0, name: $0) }
        model.selectMany(["/a", "/c"], primary: "/a")
        let source = NativeNodeTable(model: model, nodes: nodes, treeRows: [], treeMode: false,
            revision: UUID(), selectedPath: model.selection, blocked: false, selectedPaths: model.selectedPaths)
        let coordinator = source.makeCoordinator()
        let table = NodeTable()
        table.allowsMultipleSelection = true
        table.dataSource = coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        coordinator.attach(table: table, scroll: scroll)
        coordinator.update(source)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 2]))
        let reordered = NativeNodeTable(model: model, nodes: [nodes[1], nodes[2], nodes[0]], treeRows: [], treeMode: false,
            revision: UUID(), selectedPath: model.selection, blocked: false, selectedPaths: model.selectedPaths)
        coordinator.update(reordered)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([1, 2]))
        coordinator.stop()
    }

    /// 二万行可以直接跳到末尾，视口只覆盖少量行而非整个目录。
    func testLargeDirectoryScrollRange() {
        let nodes = (0..<20_000).map { NodeRow(id: "/stress-test/node-\($0)", name: "node-\($0)") }
        let source = NativeNodeTable(model: BrowserModel(), nodes: nodes, treeRows: [], treeMode: false,
                                     revision: UUID(), selectedPath: nil, blocked: false)
        let coordinator = source.makeCoordinator()
        let table = NodeTable(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        table.rowHeight = 26
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 640
        table.addTableColumn(column)
        table.dataSource = coordinator
        table.delegate = coordinator
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        coordinator.attach(table: table, scroll: scroll)
        coordinator.update(source)
        XCTAssertEqual(table.numberOfRows, 20_000)
        table.scrollRowToVisible(19_999)
        let bottom = table.rows(in: table.visibleRect)
        XCTAssertNotEqual(bottom.location, NSNotFound)
        XCTAssertEqual(NSMaxRange(bottom), 20_000)
        XCTAssertLessThan(bottom.length, 30)
        table.scrollRowToVisible(0)
        let top = table.rows(in: table.visibleRect)
        XCTAssertEqual(top.location, 0)
        coordinator.stop()
    }
}
