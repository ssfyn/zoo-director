import SwiftUI
import AppKit

/// Finder 风格的连接、目录列表与节点检查器。
struct BrowserView: View {
    /// 当前窗口的浏览状态。
    @Bindable var model: BrowserModel
    /// 管理并行连接与持久化配置的窗口状态。
    @Bindable var workspace: ConnectionWorkspace
    /// 是否聚焦地址栏。
    @FocusState private var pathFocused: Bool
    /// 待确认保存操作。
    @State private var confirmingSave = false
    /// 等待用户确认删除的连接。
    @State private var deletingConnection: ConnectionProfile?
    /// 工具栏与右侧内容区对齐，窗口缩放时同步可用宽度。
    @State private var detailWidth: CGFloat = 860

    /// 拼接三栏布局与系统工具栏。
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detailContent
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { detailWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in detailWidth = width }
                }
            }
        }
        .toolbar { navigationToolbar }
        .sheet(isPresented: Binding(get: { workspace.configuration.showingConnection },
                                    set: { workspace.configuration.showingConnection = $0 })) {
            ConnectionSheet(model: workspace.configuration, profile: workspace.configuration.editingConnection, workspace: workspace)
        }
        .sheet(isPresented: Binding(get: { model.creationParent != nil }, set: { if !$0 { model.creationParent = nil } })) {
            if let parent = model.creationParent { CreateNodeSheet(model: model, parent: parent) }
        }
        .sheet(isPresented: Binding(get: { !model.deletionTargets.isEmpty }, set: { if !$0 { model.deletionTargets = [] } })) {
            DeleteNodesSheet(model: model, targets: model.deletionTargets)
        }
        .alert(L10n.text("操作未完成"), isPresented: Binding(get: { displayedError != nil && model.creationParent == nil }, set: { if !$0 { clearError() } })) {
            Button(L10n.text("好"), role: .cancel) { clearError() }
        } message: { Text(L10n.text(displayedError ?? "")) }
        .confirmationDialog(L10n.text("保存节点数据？"), isPresented: $confirmingSave, titleVisibility: .visible) {
            Button(L10n.text("保存到 ZooKeeper")) { model.save() }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.text("将更新 \(model.inspectedPath ?? "")。使用当前版本进行检查；其他客户端修改过的数据不会被覆盖。"))
        }
        .confirmationDialog(L10n.text("删除连接？"), isPresented: Binding(
            get: { deletingConnection != nil }, set: { if !$0 { deletingConnection = nil } }
        ), titleVisibility: .visible) {
            Button(L10n.text("删除连接"), role: .destructive) {
                if let profile = deletingConnection { workspace.delete(profile) }
                deletingConnection = nil
            }
            Button(L10n.text("取消"), role: .cancel) { deletingConnection = nil }
        } message: {
            Text(L10n.text("将删除“\(deletingConnection?.displayName ?? "")”的本机配置和收藏。该连接的会话会关闭，其他会话继续保持。ZooKeeper 服务端数据不受影响。"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmSave)) { _ in confirmingSave = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusPath)) { _ in pathFocused = true }
    }

    /// 前台模型与窗口级配置操作共享一个错误提示入口。
    private var displayedError: String? { workspace.error ?? workspace.configuration.error ?? model.error }

    /// 关闭提示后清除所有当前可见的错误来源。
    private func clearError() {
        workspace.error = nil; workspace.configuration.error = nil; model.error = nil
    }

    /// 根据选择及握手状态展示空白引导、配置、加载或节点浏览。
    @ViewBuilder private var detailContent: some View {
        if let profile = model.selectedProfile {
            if model.connecting && model.activeID == profile.id {
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text(L10n.text(model.status)).font(.headline)
                    Text(profile.displayName).foregroundStyle(.secondary)
                    Button(L10n.text("取消连接")) { model.disconnect() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.showingBrowser {
                connectedContent
            } else {
                ScrollView {
                    ConnectionSheet(model: model, profile: profile, embedded: true, workspace: workspace)
                        .id(profile.id).frame(maxWidth: .infinity).padding(.vertical, 32)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView(L10n.text("选择一个连接"), systemImage: "externaldrive.connected.to.line.below",
                                       description: Text(L10n.text("从左侧选择已有连接，或添加新的连接配置。")))
                Button(L10n.text("添加连接")) { workspace.configuration.beginAddingConnection() }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 仅在连接成功后展示地址栏、节点树及检查器。
    private var connectedContent: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            HSplitView {
                nodeContent.frame(minWidth: 480)
                InspectorView(model: model, confirmingSave: $confirmingSave)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
            }
            Divider()
            statusBar
        }
    }

    /// 在连接图标右下角以灰色或绿色圆点标记实际会话状态。
    private func connectionIcon(_ profile: ConnectionProfile) -> some View {
        Image(systemName: "externaldrive.connected.to.line.below")
            .foregroundStyle(.blue).frame(width: 22, height: 24)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill((workspace.session(for: profile)?.isConnected(profile) == true) ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().stroke(.background, lineWidth: 1.5) }
                    .offset(x: 2, y: 1)
            }
            .accessibilityLabel((workspace.session(for: profile)?.isConnected(profile) == true) ? L10n.text("已连接") : L10n.text("未连接"))
    }

    /// 提供显式连接、取消或关闭会话以及配置编辑和删除操作。
    @ViewBuilder private func connectionMenu(_ profile: ConnectionProfile) -> some View {
        let session = workspace.session(for: profile)
        if session?.isConnected(profile) == true || session?.connecting == true {
            Button(session?.connecting == true ? L10n.text("取消连接") : L10n.text("关闭连接"), systemImage: "stop.circle") {
                workspace.disconnect(profile)
            }.disabled(session?.saving == true)
        } else {
            Button(L10n.text("连接"), systemImage: "bolt") { workspace.connect(profile) }.disabled(session?.saving == true)
        }
        Divider()
        Button(L10n.text("编辑连接…"), systemImage: "pencil") { workspace.configuration.beginEditingConnection(profile) }
            .disabled(session?.saving == true)
        Button(L10n.text("删除连接…"), systemImage: "trash", role: .destructive) { deletingConnection = profile }
            .disabled(session?.saving == true)
    }

    /// 展示连接管理和当前连接专属的收藏位置。
    private var sidebar: some View {
        List {
            Section(L10n.text("连接列表")) {
                ForEach(workspace.configuration.profiles) { profile in
                    Button { workspace.select(profile) } label: {
                        HStack(spacing: 9) {
                            connectionIcon(profile)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.displayName).fontWeight(.medium)
                                Text(profile.endpoint).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if workspace.session(for: profile)?.connecting == true { ProgressView().controlSize(.mini) }
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .listRowBackground(workspace.configuration.selectedConnectionID == profile.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .contextMenu { connectionMenu(profile) }
                }
            }
            favoriteSection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { workspace.configuration.beginAddingConnection() } label: {
                Label(L10n.text("添加连接"), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding()
        }
    }

    /// 收藏随连接切换，点击沿用普通目录导航和未保存内容保护。
    private var favoriteSection: some View {
        Section(L10n.text("收藏位置")) {
            if !model.showingBrowser {
                Text(L10n.text("连接后可收藏目录")).font(.caption).foregroundStyle(.secondary)
            } else if model.favorites.isEmpty {
                Text(L10n.text("右键点击目录可收藏"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.favorites, id: \.self) { path in
                    Button { model.navigate(path) } label: {
                        Label(path, systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(model.saving).help(path)
                    .contextMenu {
                        Button(L10n.text("移除收藏"), systemImage: "star.slash") { model.removeFavorite(path) }
                    }
                }
            }
        }
    }

    /// 提供可直接编辑的完整目录地址。
    private var addressBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.blue)
            TextField(L10n.text("绝对路径，例如 /services"), text: $model.pathInput)
                .font(.system(.body, design: .monospaced)).textFieldStyle(.plain)
                .focused($pathFocused).onSubmit { model.navigate(model.pathInput) }
                .disabled(model.saving)
            Button(L10n.text("前往")) { model.navigate(model.pathInput) }.disabled(model.saving)
            Button { model.beginCreatingNode() } label: { Image(systemName: "plus") }
                .help(L10n.text("新增节点 ⌘⇧N")).keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.canMutateNodes)
            Button { model.beginDeletingNodes() } label: { Image(systemName: "trash") }
                .help(L10n.text("删除所选节点 ⌘⌫")).keyboardShortcut(.delete, modifiers: .command).disabled(!model.canMutateNodes || model.deletableSelection.isEmpty)
        }.padding(.horizontal, 16).padding(.vertical, 12)
        .contextMenu {
            Button(model.isCurrentPathFavorite ? L10n.text("移除收藏") : L10n.text("收藏")) { model.toggleCurrentFavorite() }
                .disabled(!model.isCurrentPathFavorite && !model.canFavoriteCurrentPath)
        }
    }

    /// 当前目录筛选保留树操作，递归搜索才展示平铺匹配结果。
    private var nodeContent: some View {
        VStack(spacing: 0) {
            searchStatus
            if model.showingTree {
                NodeTreeView(model: model)
            } else {
                searchResults
            }
        }
    }

    /// 搜索结果使用系统行复用，不提供独立的列表浏览模式。
    private var searchResults: some View {
        NativeNodeTable(model: model, nodes: model.rows, treeRows: [], treeMode: false,
                        revision: model.rowsRevision, selectedPath: model.selection, blocked: model.dirty || model.saving, selectedPaths: model.selectedPaths)
            .overlay {
                if model.rows.isEmpty && !model.loading {
                    ContentUnavailableView(L10n.text("没有子节点"), systemImage: "folder", description: Text(L10n.text("当前目录为空，或没有匹配的节点。")))
                }
            }
    }

    /// 右上角使用紧凑的搜索框与范围选择，保留显式启动递归搜索的操作。
    private var searchControls: some View {
        HStack(spacing: 8) {
            TextField(L10n.text("搜索节点名称"), text: Binding(
                get: { model.filter }, set: { model.setSearchQuery($0) }
            )).textFieldStyle(.roundedBorder).frame(width: 210).onSubmit { model.search() }
            Picker(L10n.text("搜索范围"), selection: Binding(
                get: { model.searchScope }, set: { model.searchScope = $0; model.changeSearchScope() }
            )) {
                ForEach(SearchScope.allCases) { scope in Text(L10n.text(scope.rawValue)).tag(scope) }
            }.labelsHidden().frame(width: 115)
            if model.searching {
                Button(L10n.text("取消")) { model.cancelSearch() }
            } else if model.searchScope == .descendants {
                Button(L10n.text("搜索")) { model.search() }
                    .disabled(model.filter.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.controlSize(.regular).disabled(model.dirty || model.saving)
    }

    /// 仅在搜索时显示进度或不完整性提示，普通浏览不占用额外标题区域。
    @ViewBuilder private var searchStatus: some View {
        if model.searching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(L10n.text("已扫描 \(model.scannedDirectories) 个目录"))
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        } else if let summary = model.searchSummary {
            Text(L10n.text(summary)).font(.caption).foregroundStyle(summary.contains("不完整") ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }

    /// 将导航固定在左侧、搜索固定在右侧，并与内容区保持相同宽度。
    @ToolbarContentBuilder private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 0) {
                if model.showingBrowser { navigationControls }
                TitlebarDragArea().frame(minWidth: 24, maxWidth: .infinity).frame(height: 28)
                if model.showingBrowser { searchControls }
            }.frame(width: max(600, detailWidth - 32))
        }
    }

    /// 根节点入口位于最左侧，之后依次为后退、前进、上一级和刷新。
    private var navigationControls: some View {
        HStack(spacing: 16) {
            Button { model.navigate("/") } label: { Image(systemName: "house") }
                .disabled(model.path == "/" || model.saving)
                .help(L10n.text("回到根节点 /")).accessibilityLabel(L10n.text("回到根节点"))
            Button { model.moveHistory(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canBack || model.saving).help(L10n.text("后退 ⌘["))
            Button { model.moveHistory(1) } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canForward || model.saving).help(L10n.text("前进 ⌘]"))
            Button { model.navigate(NodePath.parent(of: model.path)) } label: { Image(systemName: "arrow.up") }
                .disabled(model.path == "/" || model.saving).help(L10n.text("上一级 ⌘↑"))
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.saving).help(L10n.text("刷新 ⌘R"))
        }.controlSize(.regular)
    }

    /// 仅为目录加载与保存显示进度，滚动补齐元信息保持后台更新。
    private var statusBar: some View {
        HStack(spacing: 8) {
            if !model.watchStatus.isEmpty { Text(L10n.text(model.watchStatus)).lineLimit(1).help(L10n.text(model.watchStatus)) }
            if model.selectedPaths.count > 1 { Text(L10n.text("已选择 \(model.selectedPaths.count) 项")) }
            if model.dirty { Text(L10n.text("未保存")).foregroundStyle(.orange) }
            HStack(spacing: 8) {
                if model.loading || model.saving { ProgressView().controlSize(.mini) }
                nodeCount
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }.frame(maxWidth: .infinity)
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// 节点计数固定在整条窗口状态栏最右端，不随左侧会话文字排列。
    private var nodeCount: some View {
        Group {
            if model.showingTree {
                Text(L10n.text("\((model.tree.rows.count - (model.tree.rows.first?.node.navigationTarget == nil ? 0 : 1)).formatted()) 个已展开节点"))
            } else {
                Text(L10n.text("\(model.names.count.formatted()) 项 · 当前范围"))
            }
        }
    }
}
