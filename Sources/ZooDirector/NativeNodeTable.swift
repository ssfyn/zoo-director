import SwiftUI
import AppKit

/// 以原生行复用展示完整列表或已展开的树，避免为所有节点创建视图。
struct NativeNodeTable: NSViewRepresentable {
    /// 语言切换时让现有原生表格刷新列标题和可见行，不重建选择状态。
    @Environment(\.locale) private var locale
    /// 节点选择与导航的共享状态。
    let model: BrowserModel
    /// 平铺目录的完整节点数据。
    let nodes: [NodeRow]
    /// 已展开树的完整节点数据。
    let treeRows: [TreeRow]
    /// 当前是否使用树状缩进与展开控件。
    let treeMode: Bool
    /// 结构变动时重新加载，元信息更新时只刷新屏幕上的行。
    let revision: UUID
    /// 当前选中的完整路径。
    let selectedPath: String?
    /// 编辑保护期间禁止折叠与展开。
    let blocked: Bool
    /// 当前多选路径，由共享模型恢复高亮。
    var selectedPaths: Set<String> = []

    /// 创建持有原生表格事件与数据源的协调器。
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// 配置系统滚动容器及可复用的固定高度表格。
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = NodeTable()
        table.style = .inset
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (id, title, width) in [("name", L10n.text("Name"), 220.0), ("created", L10n.text("Created"), 140.0),
                                  ("modified", L10n.text("Modified"), 140.0), ("children", L10n.text("Children"), 65.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 160 : width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        if let sort = model.nodeSort {
            table.sortDescriptors = [NSSortDescriptor(key: sort.key, ascending: sort.ascending)]
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelected)
        table.horizontalKey = { [weak coordinator = context.coordinator] right in coordinator?.horizontalKey(right) ?? false }
        table.openKey = { [weak coordinator = context.coordinator] in coordinator?.openSelected() }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    /// 同步结构、选择及可见行数据，不比较或重建所有行视图。
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let _ = locale
        context.coordinator.update(self)
    }

    /// 窗口切换展示方式时释放滚动监听。
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    /// 原生数据源只为系统当前请求的行创建单元格。
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        /// 当前一次界面更新的数据快照。
        private var source: NativeNodeTable
        /// 被管理的系统表格。
        private weak var table: NodeTable?
        /// 最近加载的行结构代次。
        private var revision: UUID?
        /// 路径到行号的索引。
        private var indices: [String: Int] = [:]
        /// 滚动位置变化的监听句柄。
        private var observer: (any NSObjectProtocol)?
        /// 已经为其请求过状态的屏幕邻近行。
        private var visiblePaths: Set<String> = []
        /// 合并短时间内重复的滚动和布局回调。
        private var viewportScheduled = false
        /// 程序同步选择时避免递归处理选择通知。
        private var updating = false
        /// 复用本地日期格式器，避免为每个单元格重新创建。
        private let formatter = DateFormatter()

        /// 保存初始数据，并配置紧凑的本地时间格式。
        init(_ source: NativeNodeTable) {
            self.source = source
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
        }

        /// 监听滚动范围，首屏与滚动后都只请求邻近行的元信息。
        func attach(table: NodeTable, scroll: NSScrollView) {
            self.table = table
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleViewport() }
            }
        }

        /// 解除监听并撤销未发出的屏幕范围请求。
        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            for path in visiblePaths { cancelMetadata(path) }
            visiblePaths = []
        }

        /// 返回当前目录或展开树中的完整行数。
        private var count: Int { source.treeMode ? source.treeRows.count : source.nodes.count }

        /// 按原生表格请求的行号读取数据，不构建其他行的视图。
        private func node(_ row: Int) -> NodeRow {
            source.treeMode ? source.treeRows[row].node : source.nodes[row]
        }

        /// 结构变化才重建索引；状态变化只刷新屏幕上的行。
        func update(_ source: NativeNodeTable) {
            guard let table else { return }
            self.source = source
            for (id, title) in [("name", "Name"), ("created", "Created"), ("modified", "Modified"), ("children", "Children")] {
                table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))?.title = L10n.text(title)
            }
            formatter.locale = LanguagePreferences.shared.locale
            updating = true
            if revision != source.revision || table.numberOfRows != count {
                revision = source.revision
                indices = Dictionary(uniqueKeysWithValues: (0..<count).map { (node($0).id, $0) })
                table.reloadData()
            } else {
                let range = table.rows(in: table.visibleRect)
                if range.location != NSNotFound, range.length > 0 {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: range.location..<NSMaxRange(range)),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
            }
            syncSelection()
            updating = false
            scheduleViewport()
        }

        /// 使用共享选择恢复原生高亮，包括被未保存保护拒绝的切换。
        private func syncSelection() {
            guard let table else { return }
            let paths = source.selectedPaths.isEmpty ? Set(source.selectedPath.map { [$0] } ?? []) : source.selectedPaths
            let target = IndexSet(paths.compactMap { indices[$0] })
            if table.selectedRowIndexes != target { table.selectRowIndexes(target, byExtendingSelection: false) }
        }

        /// 系统数据源取得总行数，目录不分页。
        func numberOfRows(in tableView: NSTableView) -> Int { count }

        /// 点击列标题时由系统切换方向，将排序规则交给共享模型。
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                  ["name", "created", "modified", "children"].contains(key) else { return }
            source.model.setNodeSort(NodeSort(key: key, ascending: descriptor.ascending))
        }

        /// 复用名称或文本单元格，只为进入系统视口的行填充值。
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard (0..<count).contains(row), let identifier = tableColumn?.identifier else { return nil }
            let node = node(row)
            if identifier.rawValue == "name" {
                let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NodeNameCell ?? NodeNameCell()
                cell.identifier = identifier
                let tree = source.treeMode ? source.treeRows[row] : nil
                cell.configure(node: node, tree: tree, blocked: source.blocked,
                               showPath: !source.treeMode && source.model.searchScope == .descendants,
                               relativeTo: source.model.path) { [weak self] in
                    self?.source.model.tree.toggle(node.id)
                }
                return cell
            }
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NodeMetadataCell ?? NodeMetadataCell()
            cell.identifier = identifier
            let value: String
            if node.navigationTarget != nil { value = "" }
            else {
                switch identifier.rawValue {
                case "created": value = date(node.stat?.created)
                case "modified": value = date(node.stat?.modified)
                default: value = node.stat.map { String($0.childCount) } ?? "—"
                }
            }
            cell.configure(value)
            return cell
        }

        /// 格式化服务端毫秒时间戳，未请求的数据使用占位符。
        private func date(_ value: Int64?) -> String {
            value.map { formatter.string(from: Date(timeIntervalSince1970: Double($0) / 1_000)) } ?? "—"
        }

        /// 原生选择变化后读取节点内容，保护拒绝时恢复旧选择。
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let path = (0..<count).contains(table.selectedRow) ? node(table.selectedRow).id : nil
            let paths = Set(table.selectedRowIndexes.filter { (0..<count).contains($0) }.map { node($0).id })
            source.model.selectMany(paths, primary: path)
            source = NativeNodeTable(model: source.model, nodes: source.nodes, treeRows: source.treeRows,
                                     treeMode: source.treeMode, revision: source.revision,
                                     selectedPath: source.model.selection, blocked: source.blocked, selectedPaths: source.model.selectedPaths)
            updating = true
            syncSelection()
            updating = false
        }

        /// 仅在双击或按回车时打开选中项，父目录入口同样遵循此规则。
        @objc func openSelected() {
            guard let table, (0..<count).contains(table.selectedRow) else { return }
            let node = node(table.selectedRow)
            source.model.navigate(node.navigationTarget ?? node.id)
        }

        /// 左右方向键只操作当前分支，左键在叶节点上选择父节点。
        func horizontalKey(_ right: Bool) -> Bool {
            guard source.treeMode, !source.blocked, let table, (0..<count).contains(table.selectedRow) else { return false }
            let row = source.treeRows[table.selectedRow]
            if row.node.navigationTarget != nil { return false }
            if right {
                if row.expandable, !row.expanded { source.model.tree.toggle(row.id) }
            } else if row.expanded { source.model.tree.toggle(row.id) }
            else {
                let parent = NodePath.parent(of: row.id)
                if indices[parent] != nil { source.model.select(parent) }
            }
            return true
        }

        /// 合并滚动通知，避免在原生布局回调中同步修改界面状态。
        private func scheduleViewport() {
            guard !viewportScheduled else { return }
            viewportScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.viewportScheduled = false
                self?.updateViewport()
            }
        }

        /// 只为实际视口及前后少量预读行申请状态，跳转可直接越过中间行。
        private func updateViewport() {
            guard let table else { return }
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound else { return }
            let start = max(0, range.location - 4)
            let end = min(count, NSMaxRange(range) + 4)
            guard start <= end else { return }
            let paths = Set((start..<end).compactMap { index -> String? in
                let node = node(index)
                return node.navigationTarget == nil ? node.id : nil
            })
            for path in visiblePaths.subtracting(paths) { cancelMetadata(path) }
            visiblePaths = paths
            for path in paths {
                if source.treeMode { source.model.tree.requestMetadata(path) }
                else { source.model.requestMetadata(path) }
            }
        }

        /// 按展示方式撤销尚未发送的离屏状态请求。
        private func cancelMetadata(_ path: String) {
            if source.treeMode { source.model.tree.cancelMetadata(path) }
            else { source.model.cancelMetadata(path) }
        }

        /// 为点击的节点即时创建上下文菜单。
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let create = menu.addItem(withTitle: L10n.text("New Node…"), action: #selector(createContext), keyEquivalent: "")
            create.target = self
            create.isEnabled = source.model.canMutateNodes && !source.blocked
            let remove = menu.addItem(withTitle: L10n.text("Delete Selected Nodes…"), action: #selector(deleteContext), keyEquivalent: "")
            remove.target = self
            remove.isEnabled = !contextDeletionPaths.isEmpty && source.model.canMutateNodes && !source.blocked
            menu.addItem(.separator())
            guard let path = contextPath else { return }
            for (title, action) in [(L10n.text("Open Node"), #selector(enterContext)), (L10n.text("Copy Path"), #selector(copyContext))] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
            }
            menu.addItem(.separator())
            let title = source.model.favorites.contains(path) ? L10n.text("Remove from Favorites") : L10n.text("Add to Favorites")
            let item = menu.addItem(withTitle: title, action: #selector(toggleContextFavorite), keyEquivalent: "")
            item.target = self
        }

        /// 右键已选中的一行时作用于整个多选，否则只删除右键目标。
        private var contextDeletionPaths: Set<String> {
            guard let table else { return [] }
            if table.clickedRow < 0 { return source.model.deletableSelection }
            guard (0..<count).contains(table.clickedRow) else { return [] }
            let row = node(table.clickedRow)
            guard row.navigationTarget == nil else { return [] }
            return source.model.selectedPaths.contains(row.id) ? source.model.deletableSelection : [row.id]
        }

        /// 在右键节点内部新增；空白处则在当前浏览目录内新增。
        @objc private func createContext() {
            source.model.beginCreatingNode(parent: (table?.clickedRow ?? -1) >= 0 ? contextPath : nil)
        }

        /// 将右键确定的多个目标交给可审阅的删除确认表单。
        @objc private func deleteContext() { source.model.beginDeletingNodes(contextDeletionPaths) }

        /// 定位右键点击的节点，键盘菜单则使用当前选中行。
        private var contextPath: String? {
            guard let table else { return nil }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard (0..<count).contains(row) else { return nil }
            let node = node(row)
            return node.navigationTarget ?? node.id
        }

        /// 从上下文菜单进入当前点击的节点。
        @objc private func enterContext() { if let path = contextPath { source.model.navigate(path) } }

        /// 对右键目标切换收藏状态，保持当前目录与节点选择不变。
        @objc private func toggleContextFavorite() {
            guard let path = contextPath else { return }
            if source.model.favorites.contains(path) { source.model.removeFavorite(path) }
            else { source.model.addFavorite(path) }
        }

        /// 复制上下文节点的完整路径。
        @objc private func copyContext() {
            guard let path = contextPath else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}

/// 元信息单元格与名称单元格采用相同的垂直居中布局。
final class NodeMetadataCell: NSTableCellView {
    /// 显示时间或计数的单行文本。
    private let label = NSTextField(labelWithString: "")

    /// 创建可复用容器，将文本中心约束到单元格的垂直中心。
    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
    }

    /// 此单元格仅通过代码创建，不支持归档恢复。
    required init?(coder: NSCoder) { fatalError(L10n.text("This cell does not support initialization from an archive")) }

    /// 替换复用单元格的内容，导航行传入空文本以清除旧值。
    func configure(_ value: String) { label.stringValue = value }
}

/// 为树的左右键和大目录首尾跳转提供固定成本的原生键盘行为。
final class NodeTable: NSTableView {
    /// 树状模式的方向键操作。
    var horizontalKey: ((Bool) -> Bool)?
    /// 回车进入当前选中的节点。
    var openKey: (() -> Void)?

    /// 首尾跳转直接滚动至目标行，不创建中间的行视图。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 119, numberOfRows > 0 { scrollRowToVisible(numberOfRows - 1); return }
        if event.keyCode == 115, numberOfRows > 0 { scrollRowToVisible(0); return }
        if event.keyCode == 124, horizontalKey?(true) == true { return }
        if event.keyCode == 123, horizontalKey?(false) == true { return }
        if event.keyCode == 36 { openKey?(); return }
        super.keyDown(with: event)
    }
}

/// 可以复用的名称单元格，树状缩进不改变表格数据量。
final class NodeNameCell: NSTableCellView {
    /// 控制当前分支展开的按钮。
    private let disclosure = NSButton()
    /// 节点图标。
    private let icon = NSImageView()
    /// 名称标签。
    private let label = NSTextField(labelWithString: "")
    /// 仅在元信息确认节点为临时节点时显示的文字标识。
    private let ephemeralBadge = NSTextField(labelWithString: L10n.text("Ephemeral"))
    /// 深度变化时只更新此缩进约束。
    private var indentation: NSLayoutConstraint!
    /// 当前复用行的展开操作。
    private var onToggle: (() -> Void)?

    /// 创建固定的视图层级和约束，后续滚动只替换内容。
    init() {
        super.init(frame: .zero)
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(toggle)
        label.lineBreakMode = .byTruncatingTail
        ephemeralBadge.font = .systemFont(ofSize: 10, weight: .medium)
        ephemeralBadge.textColor = .secondaryLabelColor
        ephemeralBadge.toolTip = L10n.text("Ephemeral node: automatically deleted when its creating session ends")
        ephemeralBadge.setAccessibilityLabel(L10n.text("Ephemeral node"))
        ephemeralBadge.isHidden = true
        ephemeralBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let nameContent = NSStackView(views: [label, ephemeralBadge])
        nameContent.orientation = .horizontal
        nameContent.alignment = .centerY
        nameContent.spacing = 6
        for view in [disclosure, icon, nameContent] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        indentation = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            indentation, disclosure.widthAnchor.constraint(equalToConstant: 14), disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 5), icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameContent.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameContent.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            nameContent.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        textField = label
        imageView = icon
    }

    /// 此单元格仅通过代码创建，不支持归档恢复。
    required init?(coder: NSCoder) { fatalError(L10n.text("This cell does not support initialization from an archive")) }

    /// 替换复用行内容；递归命中展示相对搜索目录的路径，普通树与导航入口保留名称。
    func configure(node: NodeRow, tree: TreeRow?, blocked: Bool, showPath: Bool = false, relativeTo directory: String = "/", onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        let displaysPath = showPath && node.navigationTarget == nil
        let prefix = directory == "/" ? "/" : directory + "/"
        let relativePath = node.id.hasPrefix(prefix) ? "./" + node.id.dropFirst(prefix.count) : node.id
        label.stringValue = displaysPath ? relativePath : node.name
        label.lineBreakMode = displaysPath ? .byTruncatingMiddle : .byTruncatingTail
        label.textColor = node.error == nil ? .labelColor : .systemOrange
        ephemeralBadge.isHidden = node.navigationTarget != nil || node.stat?.isEphemeral != true
        toolTip = node.error.map { L10n.text($0) } ?? node.id
        ephemeralBadge.stringValue = L10n.text("Ephemeral")
        ephemeralBadge.toolTip = L10n.text("Ephemeral node: automatically deleted when its creating session ends")
        ephemeralBadge.setAccessibilityLabel(L10n.text("Ephemeral node"))
        indentation.constant = CGFloat(min(tree?.depth ?? 0, 12)) * 16
        disclosure.isHidden = tree?.expandable != true
        disclosure.isEnabled = !blocked
        let expanded = tree?.expanded == true
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? L10n.text("Collapse") : L10n.text("Expand"))
        disclosure.setAccessibilityLabel("\(L10n.text(expanded ? "Collapse" : "Expand")) \(node.name)")
        let parent = node.navigationTarget != nil
        icon.image = NSImage(systemSymbolName: expanded ? "folder.fill" : "folder",
                             accessibilityDescription: parent ? L10n.text("Go to Parent") : L10n.text("Node"))
        icon.contentTintColor = .systemBlue
    }

    /// 转发当前复用行的展开点击。
    @objc private func toggle() { onToggle?() }
}
