import AppKit
import Observation

/// 列表中的单个节点，元信息按屏幕展示范围补齐。
struct NodeRow: Identifiable, Sendable {
    /// 完整路径同时作为稳定标识。
    let id: String
    /// 当前层显示的节点名。
    let name: String
    /// 成功读取的元信息。
    var stat: NodeStat?
    /// 单节点权限或并发删除等错误。
    var error: String?
    /// 导航行的实际目标；普通节点为空，不能将导航行发送给服务端读取。
    var navigationTarget: String?

    /// 非根目录生成返回上一级的入口，标识不会与合法节点路径重合。
    static func parent(of directory: String) -> NodeRow? {
        guard directory != "/" else { return nil }
        return NodeRow(id: directory + "/..", name: "..", navigationTarget: NodePath.parent(of: directory))
    }
}

/// 窗口级浏览状态，所有界面变更均在主线程执行。
@MainActor @Observable
final class BrowserModel {
    /// 当前浏览上下文的按需加载树。
    let tree = NodeTreeModel()
    /// 普通浏览及当前目录筛选都使用树，递归搜索单独展示匹配结果。
    var showingTree: Bool { searchScope == .current || filter.isEmpty }
    /// 已保存的连接，不含凭据。
    var profiles: [ConnectionProfile]
    /// 当前会话或正在建立会话的连接标识。
    var activeID: UUID?
    /// 侧栏选中的配置，与网络会话独立。
    private(set) var selectedConnectionID: UUID?
    /// 会话握手成功后才标记已连接，断线时立即恢复灰色状态。
    private(set) var connectionEstablished = false
    /// 当前是否正在建立 TCP 会话或 SSH 隧道。
    private(set) var connecting = false
    /// 建立会话的任务，不与目录读取任务共享。
    private var connectionTask: Task<Void, Never>?
    /// 阻止取消或关闭后的旧握手覆盖新连接。
    private var connectionGeneration = UUID()

    /// 当前侧栏选中的连接配置。
    var selectedProfile: ConnectionProfile? { profiles.first { $0.id == selectedConnectionID } }

    /// 成功连接后展示节点；异常断线时保留尚未保存的编辑内容。
    var showingBrowser: Bool {
        selectedConnectionID == activeID && activeID != nil && (connectionEstablished || dirty)
    }

    /// 只有握手成功且会话仍然有效时显示绿色连接标记。
    func isConnected(_ profile: ConnectionProfile) -> Bool {
        activeID == profile.id && connectionEstablished
    }

    /// 单击只选中配置，不建立网络连接，也不关闭正在使用的其他会话。
    func selectConnection(_ profile: ConnectionProfile) {
        guard selectedConnectionID != profile.id, mayLeave(), profiles.contains(where: { $0.id == profile.id }) else { return }
        selectedConnectionID = profile.id
    }
    /// 按连接稳定标识保存的收藏路径。
    private var favoritePaths: [String: [String]]
    /// 当前模型使用的本机偏好设置，测试时可传入独立存储。
    private let defaults: UserDefaults
    /// 当前连接中最近成功加载的目录，加载失败时禁止新增收藏。
    private var loadedPath: String?
    /// 当前显示目录的完整路径。
    var path = "/"
    /// 路径输入框的内容。
    var pathInput = "/"
    /// 当前层的全部子节点名称。
    var names: [String] = []
    /// 当前范围内全部可展示的节点。
    var rows: [NodeRow] = []
    /// 列表结构的代次，元信息变化不触发全量重新加载。
    private(set) var rowsRevision = UUID()
    /// 当前窗口共用的排序方式，切换目录或搜索时保留。
    private(set) var nodeSort: NodeSort?

    /// 接收列标题排序，同时更新树和搜索列表。
    func setNodeSort(_ sort: NodeSort) {
        nodeSort = sort
        if !sort.needsMetadata { requestedMetadata.formIntersection(visibleListPaths) }
        tree.setSort(sort)
        refreshListSort()
    }

    /// 更新列表顺序，并仅为数值排序补齐当前结果集的元信息。
    private func refreshListSort() {
        sortListRows()
        guard nodeSort?.needsMetadata == true, !showingTree else { return }
        let missing = rows.filter { $0.navigationTarget == nil && $0.stat == nil && $0.error == nil }.map(\.id)
        requestedMetadata.formUnion(missing)
        if let first = missing.first { requestMetadata(first) }
    }

    /// 重建排序后的路径索引，选择状态始终以路径恢复。
    private func sortListRows() {
        guard let nodeSort else { return }
        rows.sort(by: nodeSort.precedes)
        rowIndices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        rowsRevision = UUID()
    }
    /// 当前选中的完整路径。
    var selection: String? {
        didSet {
            if let selection {
                if !selectedPaths.contains(selection) { selectedPaths = [selection] }
            } else { selectedPaths = [] }
        }
    }
    /// 表格中的多选集合，父目录入口只参与导航和检查，不参与删除。
    var selectedPaths: Set<String> = []
    /// 新增表单固定的父节点，防止表单期间目标随选择漂移。
    var creationParent: String?
    /// 等待确认删除的目标快照。
    var deletionTargets: [String] = []
    /// 检查器实际读取与保存的节点；返回入口映射到当前目录，不改变表格选择。
    var inspectedPath: String? {
        guard let selection else { return nil }
        return selection == NodeRow.parent(of: path)?.id ? path : selection
    }
    /// 当前选中节点的读取结果。
    var snapshot: NodeSnapshot?
    /// 文本编辑器内容。
    var editor = ""
    /// 列表名称筛选条件，仅筛选当前层。
    var filter = ""
    /// 用户选择的搜索范围，默认仅当前层。
    var searchScope = SearchScope.current
    /// 是否正在执行递归搜索。
    var searching = false
    /// 递归搜索已经扫描的目录数量。
    var scannedDirectories = 0
    /// 搜索说明及截断提示。
    var searchSummary: String?
    /// 当前目录名称是否正在加载。
    var loading = false
    /// 当前详情任务是否运行。
    var reading = false
    /// 写入过程中禁止切换上下文。
    var saving = false
    /// 界面显示的最近一次状态。
    var status = "尚未连接"
    /// 当前连接的实时监听状态，失效时不能继续显示为实时。
    var watchStatus = ""
    /// 检查器数据已变化或节点已删除时的非阻塞提示。
    var inspectorNotice: String?
    /// 需要用户处理的错误。
    var error: String?
    /// 提示新建或编辑连接的表单。
    var showingConnection = false
    /// 正在编辑的连接；为空时表示新建。
    var editingConnection: ConnectionProfile?
    /// 浏览历史。
    private var history = ["/"]
    /// 浏览历史的当前位置。
    private var historyIndex = 0
    /// 当前服务对象。
    private var service: (any ZooKeeperService)?
    /// 当前列表任务，用于取消过时的加载。
    private var loadTask: Task<Void, Never>?
    /// 屏幕可见行的元信息工作任务。
    private var metadataTask: Task<Void, Never>?
    /// 等待补齐状态的行标识。
    private var requestedMetadata: Set<String> = []
    /// 全量列表的路径索引，避免滚动时线性查找大目录。
    private var rowIndices: [String: Int] = [:]
    /// 当前详情任务。
    private var readTask: Task<Void, Never>?
    /// 用于阻止旧连接或旧目录请求覆盖新状态的代次。
    private var generation = UUID()
    /// 当前递归搜索的任务。
    private var searchTask: Task<Void, Never>?
    /// 隔离先后搜索的结果。
    private var searchGeneration = UUID()
    /// 区分先后选中的节点。
    private var readGeneration = UUID()
    /// 检查器与搜索可见行共用的监听身份。
    private let watchOwner = UUID()
    /// 监听范围的单调递增代次。
    private var watchRevision: UInt64 = 0
    /// 与目录刷新代次独立的连接事件代次。
    private var watchConnection = UUID()
    /// 当前连接的事件消费任务。
    private var watchEventTask: Task<Void, Never>?
    /// 合并范围变更的任务。
    private var watchSyncTask: Task<Void, Never>?
    /// 合并事件刷新的任务。
    private var watchReloadTask: Task<Void, Never>?
    /// 检查器后台更新任务，保留当前编辑状态直到新数据安全到达。
    private var watchReadTask: Task<Void, Never>?
    /// 搜索结果中实际出现在屏幕附近的路径。
    private var visibleListPaths: Set<String> = []
    /// 等待刷新数据或状态的路径。
    private var watchedChanges: Set<String> = []
    /// 是否需要刷新当前层的名称筛选结果。
    private var watchedDirectoryChanged = false
    /// 事件订阅就绪后才安装关注范围。
    private var watchReady = false
    /// 保留部分路径注册失败等提示，避免被其他成功事件覆盖。
    private var watchProblem: String?
    /// 服务端能力识别后的实际监听模式。
    private var watchModeStatus = "实时监听中"
    /// 密码独立于连接配置存储，测试可以替换为内存实现。
    private let passwordStore: any DigestPasswordStore
    /// 可替换的连接工厂，用于验证外部变化与异常网络行为。
    private let serviceFactory: (@Sendable (ConnectionProfile) async throws -> any ZooKeeperService)?

    /// 只恢复本机保存的真实连接，启动时不选中或连接任何服务。
    init(defaults: UserDefaults = .standard,
         serviceFactory: (@Sendable (ConnectionProfile) async throws -> any ZooKeeperService)? = nil,
         passwordStore: any DigestPasswordStore = KeychainDigestPasswordStore()) {
        self.defaults = defaults
        self.serviceFactory = serviceFactory
        self.passwordStore = passwordStore
        PreferencesMigration.migrate(into: defaults)
        let saved = defaults.data(forKey: "zoodirector.connections")
        let decoded = saved.flatMap { try? JSONDecoder().decode([ConnectionProfile].self, from: $0) } ?? []
        profiles = decoded.filter { !$0.isDemo }
        let favorites = defaults.data(forKey: "zoodirector.favorites")
        favoritePaths = favorites.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        tree.onDirectoryChange = { [weak self] directory, values in
            guard let self, self.path == directory, self.showingTree else { return }
            self.names = values.map { NodePath.child($0, of: directory) }
        }
    }

    /// 模型释放时终止事件流与网络任务，避免后台订阅延长连接寿命。
    isolated deinit {
        watchEventTask?.cancel(); watchSyncTask?.cancel(); watchReloadTask?.cancel(); watchReadTask?.cancel()
        connectionTask?.cancel(); loadTask?.cancel(); metadataTask?.cancel(); readTask?.cancel(); searchTask?.cancel()
        let previous = service
        Task { await previous?.close() }
    }

    /// 当前连接的收藏存储键，不依赖可重复的连接名称或地址。
    private var favoriteKey: String? {
        guard let profile = profiles.first(where: { $0.id == activeID }) else { return nil }
        return profile.id.uuidString
    }

    /// 当前连接的收藏目录，未连接时不显示其他连接的收藏。
    var favorites: [String] {
        guard let favoriteKey else { return [] }
        return favoritePaths[favoriteKey] ?? []
    }

    /// 当前显示目录是否已经收藏，不随地址栏尚未提交的输入变化。
    var isCurrentPathFavorite: Bool { favorites.contains(path) }

    /// 目录成功加载后才允许新增收藏，避免保存未连接或无效的位置。
    var canFavoriteCurrentPath: Bool {
        service != nil && !loading && loadedPath == path
    }

    /// 切换当前目录的收藏状态，同一连接内的路径只保存一次。
    func toggleCurrentFavorite() {
        if isCurrentPathFavorite { removeFavorite(path); return }
        guard canFavoriteCurrentPath else { return }
        addFavorite(path)
    }

    /// 收藏右键点击的节点路径，无需切换当前目录；同一连接内不重复保存。
    func addFavorite(_ target: String) {
        guard service != nil, let favoriteKey, !favorites.contains(target),
              (try? NodePath.validate(target)) != nil else { return }
        favoritePaths[favoriteKey, default: []].append(target)
        persistFavorites()
    }

    /// 仅移除当前连接中的指定收藏，不影响同路径的其他连接。
    func removeFavorite(_ target: String) {
        guard let favoriteKey else { return }
        favoritePaths[favoriteKey]?.removeAll { $0 == target }
        persistFavorites()
    }

    /// 合并本会话的收藏修改，避免多个连接同时保存时覆盖彼此的收藏。
    private func persistFavorites(removing removedKey: String? = nil) {
        let saved = defaults.data(forKey: "zoodirector.favorites")
        var merged = saved.flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        if let removedKey { merged.removeValue(forKey: removedKey) }
        else if let favoriteKey { merged[favoriteKey] = favoritePaths[favoriteKey] ?? [] }
        guard let data = try? JSONEncoder().encode(merged) else { return }
        defaults.set(data, forKey: "zoodirector.favorites")
    }

    /// 判断文本是否与读取时的原始内容不同。
    var dirty: Bool {
        guard let snapshot, let text = String(data: snapshot.data, encoding: .utf8) else { return false }
        return text != editor
    }

    /// 当前筛选结果数量。
    var filteredCount: Int { filteredNames.count }
    /// 名称筛选后的当前层列表。
    private var filteredNames: [String] {
        searchScope == .descendants || filter.isEmpty ? names : names.filter {
            String($0.split(separator: "/").last ?? "").localizedCaseInsensitiveContains(filter)
        }
    }
    /// 是否可返回上一条历史。
    var canBack: Bool { historyIndex > 0 }
    /// 是否可前进到下一条历史。
    var canForward: Bool { historyIndex + 1 < history.count }
    /// 是否允许文本编辑，二进制和过大文本只读。
    var editable: Bool {
        guard let snapshot else { return false }
        return snapshot.data.count <= 256 * 1024 && String(data: snapshot.data, encoding: .utf8) != nil
    }

    /// 打开空白的新建连接表单，清除上一次编辑目标。
    func beginAddingConnection() {
        editingConnection = nil
        showingConnection = true
    }

    /// 打开指定真实连接的编辑表单。
    func beginEditingConnection(_ profile: ConnectionProfile) {
        guard !saving, let current = profiles.first(where: { $0.id == profile.id }), !current.isDemo else { return }
        editingConnection = current
        showingConnection = true
    }

    /// 添加并选中新配置，仅保存到本机，等待用户显式连接。
    @discardableResult
    func addConnection(name: String, endpoint: String, ssh: SSHConfiguration? = nil,
                       digest: DigestConfiguration? = nil, password: String? = nil) -> ConnectionProfile? {
        guard mayLeave() else { return nil }
        error = nil
        do {
            let authentication = try prepareDigest(digest, password: password)
            let profile = ConnectionProfile(name: name, endpoint: endpoint, ssh: ssh, digest: authentication)
            profiles.append(profile)
            persistConnections()
            selectedConnectionID = profile.id
            return profile
        } catch { self.error = error.localizedDescription; return nil }
    }

    /// 更新配置保留标识与收藏，地址、隧道或认证变化时关闭旧会话。
    @discardableResult
    func updateConnection(_ profile: ConnectionProfile, name: String, endpoint: String, ssh: SSHConfiguration? = nil,
                          digest: DigestConfiguration? = nil, password: String? = nil) -> Bool {
        guard !saving, let index = profiles.firstIndex(where: { $0.id == profile.id }),
              !profiles[index].isDemo else { return false }
        let isActive = activeID == profile.id
        guard !isActive || mayLeave() else { return false }
        error = nil
        do {
            let authentication = try prepareDigest(digest, password: password)
            let previous = profiles[index]
            let changed = previous.endpoint != endpoint || previous.ssh != ssh || previous.digest != authentication
            if isActive && changed { disconnect() }
            profiles[index].name = name
            profiles[index].endpoint = endpoint
            profiles[index].ssh = ssh
            profiles[index].digest = authentication
            persistConnections()
            if previous.digest?.credentialID != authentication?.credentialID { removeDigestPassword(previous.digest) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// 先保存新引用的密码；失败时不修改原配置，未改密码时要求原引用仍可用。
    private func prepareDigest(_ configuration: DigestConfiguration?, password: String?) throws -> DigestConfiguration? {
        guard var configuration else { return nil }
        try configuration.validate()
        if let password {
            configuration.credentialID = UUID()
            try passwordStore.save(password, id: configuration.credentialID)
        } else if try passwordStore.load(configuration.credentialID) == nil {
            throw ZooKeeperError.message("未找到 digest 密码，请编辑连接后重新输入。")
        }
        return configuration
    }

    /// 配置已提交后清理旧凭据，失败时提示但不回滚已经保存的新配置。
    private func removeDigestPassword(_ configuration: DigestConfiguration?) {
        guard let configuration else { return }
        do { try passwordStore.remove(configuration.credentialID) }
        catch { self.error = "配置已保存，但旧 digest 密码未能从钥匙串移除。" }
    }

    /// 删除连接及收藏，删除当前会话前先关闭连接，不自动连接其他服务。
    func deleteConnection(_ profile: ConnectionProfile) {
        guard !saving, let current = profiles.first(where: { $0.id == profile.id }) else { return }
        if activeID == current.id {
            guard mayLeave() else { return }
            disconnect()
        }
        if let digest = current.digest {
            do { try passwordStore.remove(digest.credentialID) }
            catch { self.error = error.localizedDescription; return }
        }
        profiles.removeAll { $0.id == current.id }
        if selectedConnectionID == current.id { selectedConnectionID = nil }
        favoritePaths.removeValue(forKey: current.id.uuidString)
        persistConnections()
        persistFavorites(removing: current.id.uuidString)
    }

    /// 将用户配置持久化，不保存运行时连接状态。
    private func persistConnections() {
        guard let data = try? JSONEncoder().encode(profiles.filter { !$0.isDemo }) else { return }
        defaults.set(data, forKey: "zoodirector.connections")
    }

    /// 在切换上下文前保护未保存的内容。
    func mayLeave() -> Bool {
        if saving { return false }
        if dirty { error = "当前数据有未保存修改。请先保存，或点击“放弃修改”后继续。"; return false }
        return true
    }

    /// 关闭或取消当前连接，保留配置及收藏，未保存内容沿用现有保护。
    func disconnect() {
        guard mayLeave() else { return }
        let previous = clearConnection()
        Task { await previous?.close() }
    }

    /// 退出已确认时直接释放本会话资源，不再次弹出未保存提示。
    func shutdown() {
        let previous = clearConnection()
        Task { await previous?.close() }
    }

    /// 清理当前浏览上下文并隔离旧任务，返回需要异步关闭的服务。
    private func clearConnection() -> (any ZooKeeperService)? {
        let previous = service
        stopWatching()
        tree.stop()
        connectionGeneration = UUID()
        connectionTask?.cancel(); connectionTask = nil
        generation = UUID(); readGeneration = UUID()
        loadTask?.cancel(); readTask?.cancel(); metadataTask?.cancel()
        metadataTask = nil; requestedMetadata = []; rowIndices = [:]
        cancelSearch()
        service = nil; loadedPath = nil; activeID = nil
        connectionEstablished = false; connecting = false
        names = []; rows = []; rowsRevision = UUID()
        selection = nil; snapshot = nil; editor = ""
        filter = ""; searchScope = .current; searchSummary = nil; scannedDirectories = 0
        path = "/"; pathInput = path; history = [path]; historyIndex = 0
        creationParent = nil; deletionTargets = []
        loading = false; reading = false; error = nil; status = "尚未连接"
        return previous
    }

    /// 用户显式连接后先展示加载状态，握手成功才开放节点浏览。
    func connect(_ profile: ConnectionProfile) {
        guard mayLeave(), !isConnected(profile), !(connecting && activeID == profile.id) else { return }
        let previous = clearConnection()
        let token = connectionGeneration
        activeID = profile.id
        selectedConnectionID = profile.id
        connecting = true; loading = true
        status = profile.ssh == nil ? "正在连接…" : "正在建立 SSH 隧道…"
        connectionTask = Task {
            await previous?.close()
            do {
                try Task.checkCancellation()
                let connected: any ZooKeeperService
                if let serviceFactory { connected = try await serviceFactory(profile) }
                else { connected = try await ZooKeeperClient.open(profile: profile, passwordStore: passwordStore) }
                guard token == connectionGeneration, !Task.isCancelled else { await connected.close(); return }
                service = connected
                connectionEstablished = true; connecting = false
                status = profile.ssh == nil ? "TCP 会话" : "SSH 隧道 · TCP 会话"
                startWatching(connected)
                refresh()
            } catch {
                guard token == connectionGeneration else { return }
                connectionEstablished = false; connecting = false; loading = false
                activeID = nil
                self.error = error.localizedDescription; status = "连接失败"
            }
        }
    }

    /// 跳转至绝对路径，并按需写入导航历史。
    func navigate(_ target: String, record: Bool = true) {
        guard mayLeave(), connectionEstablished else { return }
        do {
            let target = try NodePath.validate(target)
            path = target; pathInput = target; filter = ""; searchSummary = nil
            if record, history[historyIndex] != target {
                history = Array(history.prefix(historyIndex + 1)) + [target]
                historyIndex = history.count - 1
            }
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    /// 在当前位置与相邻历史之间移动。
    func moveHistory(_ delta: Int) {
        guard mayLeave(), history.indices.contains(historyIndex + delta) else { return }
        historyIndex += delta
        navigate(history[historyIndex], record: false)
    }

    /// 重新读取当前层的全部名称，元信息按行进入屏幕时加载。
    func refresh() {
        guard mayLeave(), connectionEstablished, let service else { return }
        tree.stop()
        metadataTask?.cancel(); metadataTask = nil; requestedMetadata = []
        if searchScope == .descendants, !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            search()
            return
        }
        cancelSearch()
        searchSummary = nil
        generation = UUID()
        let token = generation
        loadTask?.cancel(); readTask?.cancel()
        selection = nil; snapshot = nil; rows = []; names = []; reading = false; loading = true
        resetWatchView()
        let target = path
        loadedPath = nil
        loadTask = Task {
            do {
                let values = try await service.children(target)
                guard token == generation, !Task.isCancelled else { return }
                loadedPath = target
                names = values.map { NodePath.child($0, of: target) }
                if showingTree {
                    tree.reset(directory: target, names: values, service: service, filter: searchScope == .current ? filter : "")
                    loading = false
                } else { showRows() }
            } catch {
                guard token == generation else { return }
                loading = false; self.error = error.localizedDescription; status = "读取失败 · 可手动重连"
            }
        }
    }

    /// 搜索框结束编辑可能重复提交原文，仅在关键词真正变化时重置搜索上下文。
    func setSearchQuery(_ query: String) {
        guard query != filter, mayLeave() else { return }
        filter = query
        updateSearchQuery()
    }

    /// 修改关键词时立即筛选当前层，递归范围只清理旧结果而不发网络请求。
    func updateSearchQuery() {
        if searchScope == .current {
            cancelSearch()
            searchSummary = nil
            if !loading { showRows() }
            return
        }
        tree.stop()
        if showingTree { refresh(); return }
        cancelSearch(); loadTask?.cancel(); readTask?.cancel()
        generation = UUID()
        names = []; rows = []; selection = nil; snapshot = nil
        loading = false; reading = false
        resetWatchView()
        searchSummary = "按节点名搜索 · 点击搜索或按回车开始"
    }

    /// 改变范围时清除旧结果，递归搜索必须显式发起。
    func changeSearchScope() {
        guard mayLeave() else { return }
        if searchScope == .descendants, !filter.isEmpty { updateSearchQuery() }
        else { refresh() }
    }

    /// 仅当前层时本地筛选，递归时在当前路径下启动有界搜索。
    func search() {
        guard mayLeave() else { return }
        if searchScope == .current { showRows(); return }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let service else { return }
        cancelSearch(); loadTask?.cancel(); readTask?.cancel()
        generation = UUID()
        let token = searchGeneration
        let context = generation
        let target = path
        searching = true; loading = false; reading = false; scannedDirectories = 0
        selection = nil; snapshot = nil; rows = []; names = []
        resetWatchView()
        searchSummary = "正在搜索当前路径及子目录…"
        searchTask = Task {
            do {
                let result = try await NodeSearch.run(root: target, query: query, service: service) { count in
                    await self.searchProgress(count, token: token)
                }
                guard token == searchGeneration, context == generation, !Task.isCancelled else { return }
                names = result.paths.sorted()
                searching = false
                searchSummary = "扫描 \(result.scanned) 个目录 · 跳过 \(result.skipped) 个不可读取目录"
                    + (result.limited ? " · 已达上限，结果不完整" : " · 搜索完成")
                showRows()
            } catch {
                guard token == searchGeneration else { return }
                searching = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    /// 只发布当前搜索的扫描进度。
    private func searchProgress(_ count: Int, token: UUID) {
        if token == searchGeneration { scannedDirectories = count }
    }

    /// 中止递归遍历，已发出的少量只读请求由连接层正常回收。
    func cancelSearch() {
        searchTask?.cancel()
        searchGeneration = UUID()
        if searching { searchSummary = "搜索已取消 · 已扫描 \(scannedDirectories) 个目录" }
        searching = false
    }

    /// 完整展示当前范围的全部名称，由可见行再请求元信息。
    func showRows() {
        guard mayLeave(), service != nil else { return }
        loadTask?.cancel(); readTask?.cancel(); metadataTask?.cancel()
        metadataTask = nil; requestedMetadata = []
        generation = UUID()
        rows = filteredNames.map { NodeRow(id: $0, name: String($0.split(separator: "/").last ?? "")) }
        if let parent = NodeRow.parent(of: path) { rows.insert(parent, at: 0) }
        rowIndices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        rowsRevision = UUID()
        selection = nil; snapshot = nil; reading = false; loading = false
        resetWatchView()
        if searchScope == .current { tree.setFilter(filter) }
        refreshListSort()
    }

    /// 仅为进入屏幕的行排队请求元信息，同一行不会重复请求。
    func requestMetadata(_ path: String) {
        guard let index = rowIndices[path], rows.indices.contains(index),
              rows[index].navigationTarget == nil, let service else { return }
        if visibleListPaths.insert(path).inserted { scheduleWatchSync() }
        guard rows[index].stat == nil, rows[index].error == nil else { return }
        requestedMetadata.insert(path)
        guard metadataTask == nil else { return }
        let token = generation
        metadataTask = Task {
            while token == generation, !Task.isCancelled {
                let paths = Array(requestedMetadata.sorted().prefix(8))
                if paths.isEmpty { break }
                requestedMetadata.subtract(paths)
                let batch = paths.compactMap { path -> NodeRow? in
                    guard let index = rowIndices[path] else { return nil }
                    return rows[index]
                }
                let loaded = await Self.fetchMetadata(batch, service: service)
                guard token == generation, !Task.isCancelled else { return }
                requestedMetadata.subtract(paths)
                for item in loaded {
                    if let index = rowIndices[item.id] { rows[index] = item }
                }
            }
            if token == generation {
                metadataTask = nil
                if nodeSort?.needsMetadata == true { sortListRows() }
            }
        }
    }

    /// 行离开屏幕后取消还未发出的状态请求。
    func cancelMetadata(_ path: String) {
        if nodeSort?.needsMetadata != true { requestedMetadata.remove(path) }
        if visibleListPaths.remove(path) != nil { scheduleWatchSync() }
    }

    /// 在后台并行读取一批节点状态，单节点失败不会中断整个列表。
    nonisolated private static func fetchMetadata(_ batch: [NodeRow], service: any ZooKeeperService) async -> [NodeRow] {
        await withTaskGroup(of: NodeRow.self) { group in
            for row in batch {
                group.addTask {
                    var result = row
                    do { result.stat = try await service.stat(row.id) }
                    catch { result.error = error.localizedDescription }
                    return result
                }
            }
            var results: [NodeRow] = []
            for await item in group { results.append(item) }
            return results
        }
    }

    /// 选择返回入口时检查当前目录，普通节点检查自身，并丢弃过时的读取结果。
    func select(_ target: String?) {
        guard target != selection else { return }
        guard mayLeave() else { return }
        readTask?.cancel()
        readGeneration = UUID()
        let token = readGeneration
        let context = generation
        selection = target; snapshot = nil; editor = ""; reading = target != nil
        inspectorNotice = nil
        watchReadTask?.cancel()
        scheduleWatchSync()
        guard let target = inspectedPath, let service else { reading = false; return }
        readTask = Task {
            do {
                let value = try await service.read(target)
                guard token == readGeneration, context == generation, !Task.isCancelled else { return }
                snapshot = value
                editor = String(data: value.data, encoding: .utf8) ?? ""
                reading = false
            } catch {
                guard token == readGeneration, context == generation else { return }
                reading = false; self.error = error.localizedDescription
            }
        }
    }

    /// 放弃编辑并恢复读取时的文本。
    func discard() {
        editor = snapshot.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        if inspectorNotice != nil { reloadInspector() }
    }

    /// 保留路径与版本快照执行写入，成功后重新读取以取得新版本。
    func save() {
        guard connectionEstablished, dirty, editable, !saving, let service, let selection = inspectedPath, let snapshot else { return }
        saving = true
        let data = Data(editor.utf8)
        Task {
            do {
                try await service.write(selection, data: data, version: snapshot.stat.version)
                let value = try await service.read(selection)
                self.snapshot = value; editor = String(data: value.data, encoding: .utf8) ?? ""
                inspectorNotice = nil
                if let index = rows.firstIndex(where: { $0.id == selection }) { rows[index].stat = value.stat }
                if showingTree { tree.updateMetadata(selection, stat: value.stat) }
                status = "已保存 · 版本 \(value.stat.version)"
            } catch {
                self.error = "\(error.localizedDescription)\n若服务端可能已收到写入，请重新读取后确认结果。"
            }
            saving = false
        }
    }
}

extension BrowserModel {
    /// 清空上一连接的监听任务与范围，仍保留已保存的连接和收藏配置。
    private func stopWatching() {
        let previous = service
        watchRevision += 1
        let revision = watchRevision
        let owner = watchOwner
        Task { await previous?.watch([], owner: owner, revision: revision) }
        watchConnection = UUID()
        watchEventTask?.cancel(); watchSyncTask?.cancel(); watchReloadTask?.cancel(); watchReadTask?.cancel()
        watchReady = false; watchProblem = nil; watchStatus = ""
        watchModeStatus = "实时监听中"
        visibleListPaths = []; watchedChanges = []; watchedDirectoryChanged = false; inspectorNotice = nil
    }

    /// 创建独立的事件消费者，旧连接的通知不能影响新连接。
    private func startWatching(_ service: any ZooKeeperService) {
        let token = watchConnection
        watchStatus = "监听准备中"
        watchEventTask = Task { [weak self] in
            let stream = await service.watchEvents()
            guard token == self?.watchConnection, !Task.isCancelled else { return }
            self?.watchReady = true
            self?.scheduleWatchSync()
            for await event in stream {
                guard let self else { return }
                guard token == self.watchConnection, !Task.isCancelled else { return }
                self.receiveWatchEvent(event)
            }
        }
    }

    /// 目录切换时停止旧检查器更新，但保留连接级事件消费任务。
    private func resetWatchView() {
        visibleListPaths = []; watchedChanges = []; watchedDirectoryChanged = false
        watchReadTask?.cancel(); watchReloadTask?.cancel(); watchReloadTask = nil
        inspectorNotice = nil
        scheduleWatchSync()
    }

    /// 检查器和搜索可见行共享监听；普通目录的监听由树模型管理。
    private var inspectorWatchPaths: Set<String> {
        var paths = visibleListPaths
        if let inspectedPath { paths.insert(inspectedPath) }
        if !showingTree, searchScope == .current { paths.insert(path) }
        return paths
    }

    /// 合并选择和滚动变化，固定代次防止过时请求恢复旧监听。
    private func scheduleWatchSync() {
        guard watchReady, let service else { return }
        watchRevision += 1
        let revision = watchRevision
        let owner = watchOwner
        let paths = inspectorWatchPaths
        watchSyncTask?.cancel()
        watchSyncTask = Task {
            do { try await Task.sleep(for: .milliseconds(30)); try Task.checkCancellation() }
            catch { return }
            await service.watch(paths, owner: owner, revision: revision)
        }
    }

    /// 处理连接状态并聚合需要刷新的路径，不将后台变化当作用户操作弹窗。
    private func receiveWatchEvent(_ event: WatchEvent) {
        switch event {
        case .mode(let description):
            watchModeStatus = description
            if watchProblem == nil, watchStatus.contains("监听中") { watchStatus = description }
            return
        case .unavailable(let reason):
            watchProblem = reason; watchStatus = reason
            return
        case .disconnected(let reason):
            connectionEstablished = false
            watchReady = false
            watchStatus = "实时更新已停止：\(reason)；请重新连接"
            status = "连接已断开"
            watchSyncTask?.cancel(); watchReloadTask?.cancel(); watchReadTask?.cancel()
            inspectorNotice = dirty ? "连接已断开，未保存编辑已保留。请重新连接。" : reason
            return
        case .resync(let target):
            if watchProblem == nil { watchStatus = watchModeStatus }
            if let target { watchedChanges.insert(target) }
            else { watchedChanges.formUnion(inspectorWatchPaths) }
            if target == nil || target == path { watchedDirectoryChanged = true }
        case .changed(let target, let change):
            watchedChanges.insert(target)
            if target == path, change == .children || change == .deleted || change == .created {
                watchedDirectoryChanged = true
            }
        }
        watchedChanges.formIntersection(inspectorWatchPaths)
        guard !watchedChanges.isEmpty, watchReloadTask == nil else { return }
        let token = watchConnection
        let context = generation
        watchReloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
            catch { return }
            guard let self, token == self.watchConnection, context == self.generation else { return }
            self.watchReloadTask = nil
            await self.applyWatchChanges(context: context)
        }
    }

    /// 仅更新搜索可见状态与检查器，树自己处理展开目录的局部变化。
    private func applyWatchChanges(context: UUID) async {
        let paths = watchedChanges
        watchedChanges.removeAll()
        let refreshNames = watchedDirectoryChanged
        watchedDirectoryChanged = false
        if let inspectedPath, paths.contains(inspectedPath) { refreshInspectorFromWatch() }
        if refreshNames, !showingTree, searchScope == .current { await reloadWatchedSearchDirectory(context: context) }
        guard context == generation else { return }
        for path in paths.intersection(visibleListPaths) {
            if let index = rowIndices[path] {
                rows[index].stat = nil; rows[index].error = nil
                requestMetadata(path)
            }
        }
    }

    /// 当前层名称变化时重算名称筛选，保留选中路径与未保存的检查器内容。
    private func reloadWatchedSearchDirectory(context: UUID) async {
        guard let service else { return }
        let target = path
        do {
            let values = try await service.children(target)
            guard context == generation, target == path, !Task.isCancelled else { return }
            let cached = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            names = values.map { NodePath.child($0, of: target) }
            rows = filteredNames.map { cached[$0] ?? NodeRow(id: $0, name: String($0.split(separator: "/").last ?? "")) }
            if let parent = NodeRow.parent(of: path) { rows.insert(parent, at: 0) }
            rowIndices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
            rowsRevision = UUID()
            visibleListPaths.formIntersection(Set(rowIndices.keys))
            scheduleWatchSync()
            refreshListSort()
        } catch {
            guard context == generation else { return }
            watchStatus = "目录刷新失败：\(error.localizedDescription)"
        }
    }

    /// 服务端发生变化时保留正在编辑的内容；没有编辑时自动取得最新数据。
    private func refreshInspectorFromWatch() {
        guard let target = inspectedPath, let service else { return }
        guard !dirty, !saving else {
            inspectorNotice = "服务端节点已变化，当前编辑已保留。放弃修改后可读取最新数据。"
            return
        }
        readTask?.cancel(); watchReadTask?.cancel()
        readGeneration = UUID()
        let token = readGeneration
        let context = generation
        reading = true
        watchReadTask = Task { [weak self] in
            do {
                let value = try await service.read(target)
                guard let self, token == self.readGeneration, context == self.generation, !Task.isCancelled else { return }
                self.reading = false
                guard !self.dirty, !self.saving else {
                    self.inspectorNotice = "服务端节点已变化，当前编辑已保留。放弃修改后可读取最新数据。"
                    return
                }
                self.snapshot = value
                self.editor = String(data: value.data, encoding: .utf8) ?? ""
                self.inspectorNotice = nil
            } catch {
                guard let self, token == self.readGeneration, context == self.generation, !Task.isCancelled else { return }
                self.reading = false
                if !self.dirty, !self.saving { self.snapshot = nil; self.editor = "" }
                if case ZooKeeperError.server(-101) = error {
                    self.inspectorNotice = "当前节点已被删除；如果重新创建，将自动恢复显示。"
                } else { self.inspectorNotice = "自动读取失败：\(error.localizedDescription)" }
            }
        }
    }

    /// 用户明确请求重新读取时仍沿用未保存内容保护。
    func reloadInspector() {
        guard mayLeave() else { return }
        let target = selection
        selection = nil
        select(target)
    }
}


extension BrowserModel {
    /// 同步原生多选与检查器焦点，未保存编辑拒绝切换时保留原选择。
    func selectMany(_ paths: Set<String>, primary: String?) {
        guard paths != selectedPaths || primary != selection else { return }
        guard mayLeave() else { return }
        select(primary)
        selectedPaths = paths
    }

    /// 当前连接及目录可操作时才启用结构写入入口。
    var canMutateNodes: Bool { connectionEstablished && !loading && !saving }

    /// 删除入口忽略父目录导航行与根节点。
    var deletableSelection: Set<String> {
        selectedPaths.filter { $0 != "/" && $0 != NodeRow.parent(of: path)?.id }
    }

    /// 在当前目录或上下文节点下打开新增表单。
    func beginCreatingNode(parent: String? = nil) {
        guard mayLeave(), canMutateNodes else { return }
        creationParent = parent ?? path
    }

    /// 固定并校验本次删除的全部目标，确认前不向服务端发送写入。
    func beginDeletingNodes(_ targets: Set<String>? = nil) {
        guard mayLeave(), canMutateNodes else { return }
        do { deletionTargets = try NodeMutations.deletionRoots(targets ?? deletableSelection) }
        catch { self.error = error.localizedDescription }
    }

    /// 创建单个节点，保持当前浏览位置并刷新相关目录。
    func createNode(parent: String, name: String, text: String, ephemeral: Bool) async -> Bool {
        guard mayLeave(), canMutateNodes, let service else { return false }
        do {
            let target = try NodeMutations.creationPath(parent: parent, name: name)
            saving = true
            try await service.create(target, data: Data(text.utf8), ephemeral: ephemeral)
            saving = false
            await reloadAfterMutation(paths: [parent, target])
            status = "已新增节点 · \(target)"
            return true
        } catch {
            saving = false
            self.error = "\(error.localizedDescription)\n若发生网络中断，请先刷新确认节点是否已创建，再决定是否重试。"
            return false
        }
    }

    /// 执行已确认的批量删除，部分失败后仍刷新目录以反映真实结果。
    func deleteNodes(recursive: Bool) async {
        guard mayLeave(), canMutateNodes, !deletionTargets.isEmpty, let service else { return }
        let targets = deletionTargets
        deletionTargets = []
        saving = true
        readTask?.cancel(); watchReadTask?.cancel()
        do {
            let count = try await NodeMutations.delete(paths: targets, recursive: recursive, service: service)
            status = "已删除 \(count) 个节点"
        } catch { self.error = error.localizedDescription }
        saving = false
        select(nil)
        await reloadAfterMutation(paths: Set(targets + targets.map { NodePath.parent(of: $0) }))
    }

    /// 显式补偿监听延迟，普通树保留展开状态，递归搜索重新获取结果。
    private func reloadAfterMutation(paths: Set<String>) async {
        if searchScope == .descendants, !filter.isEmpty { refresh(); return }
        tree.reload(paths: paths)
        await reloadWatchedSearchDirectory(context: generation)
    }
}
