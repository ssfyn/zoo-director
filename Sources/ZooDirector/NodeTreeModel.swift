import Foundation
import Observation

/// 树中一个目录已经加载的完整名称。
struct TreeBranch {
    /// 完整的直接子节点名称，未读取时为空值。
    var names: [String]?
    /// 加载此目录失败时的错误说明。
    var error: String?
}

/// 原生表格使用的已展开树行。
struct TreeRow: Identifiable {
    /// 节点的完整路径。
    var id: String
    /// 当前节点的数据与元信息。
    var node: NodeRow
    /// 相对于浏览起点的缩进层级。
    var depth: Int
    /// 当前节点是否展开。
    var expanded: Bool
    /// 当前节点是否允许继续展开。
    var expandable: Bool
}

/// 按需展开并限制元信息并发的树状态，不依赖界面组件的行生命周期。
@MainActor @Observable
final class NodeTreeModel {
    /// 当前打开的目录，只展示其子节点，不重复展示目录自身。
    private(set) var directory = "/"
    /// 已展平的可见行，折叠的后代不参与视图构建。
    private(set) var rows: [TreeRow] = []
    /// 仅在展开结构变化时更新的表格代次。
    private(set) var revision = UUID()
    /// 展开中的节点路径集合。
    private(set) var expanded: Set<String> = []
    /// 已请求过的完整目录名称。
    private var branches: [String: TreeBranch] = [:]
    /// 可见行的路径索引，补齐元信息时直接更新对应行。
    private var rowIndices: [String: Int] = [:]
    /// 当前上下文中缓存的节点元信息。
    private var metadata: [String: NodeRow] = [:]
    /// 当前会话使用的访问接口。
    private var service: (any ZooKeeperService)?
    /// 唯一后台工作任务，目录请求和元信息批次顺序执行。
    private var worker: Task<Void, Never>?
    /// 切换连接或刷新后丢弃旧结果的代次。
    private var generation = UUID()
    /// 是否正在加载当前展开范围。
    private(set) var loading = false
    /// 仅筛选浏览起点的直接子节点，手动展开的后代保持完整。
    private var filter = ""
    /// 当前同级排序规则，未指定时保留原始目录顺序。
    private var sort: NodeSort?

    /// 切换排序并补齐已展开范围内排序所需的状态。
    func setSort(_ sort: NodeSort?) {
        self.sort = sort
        if sort?.needsMetadata != true { requestedMetadata.formIntersection(visibleMetadata) }
        rebuild()
        startWorker()
    }
    /// 已进入屏幕、尚未补齐元信息的路径。
    private var requestedMetadata: Set<String> = []
    /// 当前屏幕附近的节点，不因元信息缓存命中而停止监听。
    private var visibleMetadata: Set<String> = []
    /// 正在读取的状态路径，避免视口重绘重复排队。
    private var inFlightMetadata: Set<String> = []
    /// 状态失效代次，变化事件到达后不能应用旧请求的结果。
    private var metadataEpochs: [String: UInt64] = [:]
    /// 等待重新读取的展开目录。
    private var refreshBranches: Set<String> = []
    /// 该树独立的监听身份。
    private let watchOwner = UUID()
    /// 监听范围更新的单调递增代次。
    private var watchRevision: UInt64 = 0
    /// 监听范围同步任务。
    private var watchSyncTask: Task<Void, Never>?
    /// 当前连接的事件消费者。
    private var watchEventTask: Task<Void, Never>?
    /// 合并短时间内多次变化的任务。
    private var watchReloadTask: Task<Void, Never>?
    /// 等待批量处理的变化路径。
    private var changedPaths: Set<String> = []
    /// 事件消费者注册后才开始安装服务端监听。
    private var watchReady = false
    /// 当前目录的名称更新后同步外层计数与名称筛选缓存。
    var onDirectoryChange: (@MainActor (String, [String]) -> Void)?

    /// 树模型释放时取消消费者，并清除该身份的服务端监听范围。
    isolated deinit {
        worker?.cancel(); watchSyncTask?.cancel(); watchEventTask?.cancel(); watchReloadTask?.cancel()
        let previous = service
        let owner = watchOwner
        let revision = watchRevision + 1
        Task { await previous?.watch([], owner: owner, revision: revision) }
    }

    /// 清空旧上下文，以当前层的完整名称初始化目录。
    func reset(directory: String, names: [String], service: any ZooKeeperService, filter: String = "") {
        stop()
        self.directory = directory
        self.service = service
        self.filter = filter
        branches = [directory: TreeBranch(names: names)]
        metadata = [:]
        expanded = []
        rebuild()
        startWorker()
        startWatching(service)
    }

    /// 停止旧任务，并清除跨连接或跨目录的缓存。
    func stop() {
        let previous = service
        watchRevision += 1
        let subscriptionRevision = watchRevision
        let owner = watchOwner
        Task { await previous?.watch([], owner: owner, revision: subscriptionRevision) }
        watchSyncTask?.cancel(); watchEventTask?.cancel(); watchReloadTask?.cancel()
        watchReady = false
        visibleMetadata = []; inFlightMetadata = []; metadataEpochs = [:]; refreshBranches = []; changedPaths = []
        generation = UUID()
        worker?.cancel()
        worker = nil
        service = nil
        revision = UUID()
        rows = []; branches = [:]; metadata = [:]; expanded = []; rowIndices = [:]
        loading = false; requestedMetadata = []; filter = ""
    }

    /// 本地改变当前层的名称筛选，保留展开集合与已读取分支，不递归搜索。
    func setFilter(_ query: String) {
        guard filter != query else { return }
        filter = query
        rebuild()
        startWorker()
    }

    /// 将成功保存后的元信息同步到当前树行。
    func updateMetadata(_ path: String, stat: NodeStat) {
        var node = metadata[path] ?? NodeRow(id: path, name: String(path.split(separator: "/").last ?? "/"))
        node.stat = stat
        node.error = nil
        applyMetadata([node])
    }

    /// 切换展开状态，只在需要时请求该节点的直接子节点。
    func toggle(_ path: String) {
        guard rows.contains(where: { $0.id == path && $0.expandable }) else { return }
        if expanded.contains(path) { expanded.remove(path) }
        else {
            expanded.insert(path)
            if branches[path]?.error != nil { branches[path] = nil }
        }
        rebuild()
        startWorker()
    }

    /// 由实际显示的行请求元信息，不预先读取整个展开目录的状态。
    func requestMetadata(_ path: String) {
        guard let index = rowIndices[path], rows[index].node.navigationTarget == nil else { return }
        if visibleMetadata.insert(path).inserted { scheduleWatchSync() }
        guard metadata[path] == nil, !inFlightMetadata.contains(path) else { return }
        requestedMetadata.insert(path)
        startWorker()
    }

    /// 行离开屏幕后撤销尚未发出的状态请求。
    func cancelMetadata(_ path: String) {
        if sort?.needsMetadata != true { requestedMetadata.remove(path) }
        if visibleMetadata.remove(path) != nil { scheduleWatchSync() }
    }

    /// 从展开集合重建扁平行，并更新路径索引。
    private func rebuild() {
        var visible: [TreeRow] = []
        if let parent = NodeRow.parent(of: directory) {
            visible.append(TreeRow(id: parent.id, node: parent, depth: 0, expanded: false, expandable: false))
        }
        for name in sortedNames(in: directory) where filter.isEmpty || name.localizedCaseInsensitiveContains(filter) {
            append(NodePath.child(name, of: directory), depth: 0, into: &visible)
        }
        rows = visible
        revision = UUID()
        rowIndices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        requestedMetadata.formIntersection(Set(visible.map(\.id)))
        if sort?.needsMetadata == true {
            requestedMetadata.formUnion(visible.filter {
                $0.node.navigationTarget == nil && metadata[$0.id] == nil && !inFlightMetadata.contains($0.id)
            }.map(\.id))
        }
        visibleMetadata.formIntersection(Set(visible.map(\.id)))
        scheduleWatchSync()
    }

    /// 只遍历已展开的缓存目录，完整展示其直接子节点名称。
    private func append(_ path: String, depth: Int, into rows: inout [TreeRow]) {
        var node = metadata[path] ?? NodeRow(id: path, name: path == "/" ? "/" : String(path.split(separator: "/").last ?? ""))
        node.error = branches[path]?.error ?? node.error
        let canExpand = node.stat?.childCount != 0 || branches[path]?.names?.isEmpty == false
        rows.append(TreeRow(id: path, node: node, depth: depth, expanded: expanded.contains(path), expandable: canExpand))
        guard expanded.contains(path) else { return }
        for name in sortedNames(in: path) { append(NodePath.child(name, of: path), depth: depth + 1, into: &rows) }
    }

    /// 只排序直接子节点，递归展平仍保留父子关系。
    private func sortedNames(in path: String) -> [String] {
        let names = branches[path]?.names ?? []
        guard let sort else { return names }
        let nodes = names.map { name in
            let id = NodePath.child(name, of: path)
            return metadata[id] ?? NodeRow(id: id, name: name)
        }
        return nodes.sorted(by: sort.precedes).map(\.name)
    }

    /// 启动唯一工作循环，已经运行时由循环自己发现新展开的节点。
    private func startWorker() {
        guard worker == nil, service != nil else { return }
        let token = generation
        loading = true
        worker = Task {
            await work(token: token)
            guard token == generation else { return }
            worker = nil
            loading = false
        }
    }

    /// 优先处理用户展开的目录，再按八个一批补齐可见行的元信息。
    private func work(token: UUID) async {
        guard let service else { return }
        while token == generation, !Task.isCancelled {
            let active = activeDirectories
            let missing = rows.first(where: { expanded.contains($0.id) && branches[$0.id] == nil })?.id
            if let path = refreshBranches.intersection(active).sorted().first ?? missing {
                refreshBranches.remove(path)
                do {
                    let names = try await service.children(path)
                    guard token == generation, !Task.isCancelled else { return }
                    branches[path] = TreeBranch(names: names)
                    if path == directory { onDirectoryChange?(path, names) }
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    branches[path] = TreeBranch(names: [], error: error.localizedDescription)
                }
                rebuild()
                continue
            }
            let paths = Array(requestedMetadata.sorted().prefix(8))
            if paths.isEmpty { return }
            requestedMetadata.subtract(paths)
            inFlightMetadata.formUnion(paths)
            let epochs = Dictionary(uniqueKeysWithValues: paths.map { ($0, metadataEpochs[$0, default: 0]) })
            let nodes = paths.map { NodeRow(id: $0, name: String($0.split(separator: "/").last ?? "/")) }
            let values = await Self.fetch(nodes, service: service)
            guard token == generation, !Task.isCancelled else { return }
            inFlightMetadata.subtract(paths)
            applyMetadata(values.filter { metadataEpochs[$0.id, default: 0] == epochs[$0.id] })
        }
    }

    /// 只替换状态发生变化的行，避免为每批响应重建整棵大目录树。
    private func applyMetadata(_ values: [NodeRow]) {
        for value in values {
            metadata[value.id] = value
            guard let index = rowIndices[value.id] else { continue }
            rows[index].node = value
            rows[index].node.error = branches[value.id]?.error ?? value.error
            rows[index].expandable = value.stat?.childCount != 0 || branches[value.id]?.names?.isEmpty == false
        }
        if sort?.needsMetadata == true, requestedMetadata.isEmpty, inFlightMetadata.isEmpty { rebuild() }
    }

    /// 并行读取有限的一批元信息，不下载节点内容。
    nonisolated private static func fetch(_ nodes: [NodeRow], service: any ZooKeeperService) async -> [NodeRow] {
        await withTaskGroup(of: NodeRow.self) { group in
            for node in nodes {
                group.addTask {
                    var node = node
                    do { node.stat = try await service.stat(node.id) }
                    catch { node.error = error.localizedDescription }
                    return node
                }
            }
            var results: [NodeRow] = []
            for await node in group { results.append(node) }
            return results
        }
    }
}

extension NodeTreeModel {
    /// 当前目录与实际仍然可见的展开分支，不监听折叠祖先下的隐藏分支。
    private var activeDirectories: Set<String> {
        Set(rows.filter { expanded.contains($0.id) }.map(\.id)).union([directory])
    }

    /// 先订阅事件，再安装路径监听，避免首次同步事件被遗漏。
    private func startWatching(_ service: any ZooKeeperService) {
        let token = generation
        watchEventTask = Task { [weak self] in
            let stream = await service.watchEvents()
            guard token == self?.generation, !Task.isCancelled else { return }
            self?.watchReady = true
            self?.scheduleWatchSync()
            for await event in stream {
                guard let self else { return }
                guard token == self.generation, !Task.isCancelled else { return }
                self.queueWatchEvent(event)
            }
        }
    }

    /// 合并滚动和展开产生的范围变更，代次保证迟到的旧任务不能恢复旧监听。
    private func scheduleWatchSync() {
        guard watchReady, let service else { return }
        watchRevision += 1
        let revision = watchRevision
        let owner = watchOwner
        let paths = activeDirectories.union(visibleMetadata)
        watchSyncTask?.cancel()
        watchSyncTask = Task {
            do { try await Task.sleep(for: .milliseconds(30)); try Task.checkCancellation() }
            catch { return }
            await service.watch(paths, owner: owner, revision: revision)
        }
    }

    /// 按路径聚合通知，事件风暴不会为同一路径创建大量刷新任务。
    private func queueWatchEvent(_ event: WatchEvent) {
        let interested = activeDirectories.union(visibleMetadata)
        switch event {
        case .changed(let path, _): if interested.contains(path) { changedPaths.insert(path) }
        case .resync(let path):
            if let path { if interested.contains(path) { changedPaths.insert(path) } }
            else { changedPaths.formUnion(interested) }
        default: return
        }
        guard !changedPaths.isEmpty, watchReloadTask == nil else { return }
        let token = generation
        watchReloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
            catch { return }
            guard let self, token == self.generation else { return }
            self.watchReloadTask = nil
            self.invalidateWatchedPaths()
        }
    }

    /// 保留展开与选择，仅重新读取发生变化的目录和屏幕状态。
    private func invalidateWatchedPaths() {
        let paths = changedPaths
        changedPaths.removeAll()
        refreshBranches.formUnion(paths.intersection(activeDirectories))
        for path in paths.intersection(visibleMetadata) {
            metadata.removeValue(forKey: path)
            metadataEpochs[path, default: 0] += 1
            requestedMetadata.insert(path)
        }
        startWorker()
    }
}


extension NodeTreeModel {
    /// 本客户端写入后主动刷新相关分支，不依赖服务端通知到达时机。
    func reload(paths: Set<String>) {
        for path in paths { queueWatchEvent(.resync(path)) }
    }
}
