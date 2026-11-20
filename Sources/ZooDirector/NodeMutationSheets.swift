import SwiftUI

/// 固定父节点的新建表单，失败时保留输入以便用户检查。
struct CreateNodeSheet: View {
    /// 当前窗口的节点写入模型。
    @Bindable var model: BrowserModel
    /// 本次新节点所属的完整父路径。
    let parent: String
    /// 用户输入的单层名称。
    @State private var name = ""
    /// 新节点的初始文本内容。
    @State private var text = ""
    /// 是否创建会话级临时节点。
    @State private var ephemeral = false

    /// 展示名称、类型、初始内容和明确的创建动作。
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("New Node")).font(.title2.bold())
            Text(L10n.text("Parent: \(parent)")).textSelection(.enabled).lineLimit(3)
            TextField(L10n.text("Node name"), text: $name)
            Picker(L10n.text("Node type"), selection: $ephemeral) {
                Text(L10n.text("Persistent node")).tag(false)
                Text(L10n.text("Ephemeral node")).tag(true)
            }
            if ephemeral { Text(L10n.text("Automatically deleted when the current connection's session ends. Cannot have children.")).font(.caption).foregroundStyle(.secondary) }
            Text(L10n.text("Initial content (optional)"))
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .frame(height: 160).border(.separator)
            Text(L10n.text(model.selectedProfile?.digest == nil ? "Permissions: world:anyone, read and write." : "Permissions: read/write access for the current digest identity.")) .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("Cancel")) { model.creationParent = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Create")) {
                    Task {
                        if await model.createNode(parent: parent, name: name, text: text, ephemeral: ephemeral) {
                            model.creationParent = nil
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }.padding(24).frame(width: 480).disabled(model.saving).interactiveDismissDisabled(model.saving)
        .alert(L10n.text("Could Not Create Node"), isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { model.error = nil }
        } message: { Text(L10n.text(model.error ?? "")) }
    }
}

/// 删除确认中固定展示本次目标，递归删除必须额外显式启用。
struct DeleteNodesSheet: View {
    /// 当前窗口的删除状态与执行入口。
    @Bindable var model: BrowserModel
    /// 确认期间固定的去重目标，不随后台列表变动。
    let targets: [String]
    /// 默认只允许删除空节点，避免误删整棵子树。
    @State private var recursive = false

    /// 展示目标清单、递归选项和不可撤销的最终操作。
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Delete \(targets.count) nodes?")).font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(targets, id: \.self) { Text($0).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.frame(maxHeight: 180)
            Toggle(L10n.text("Delete all child nodes"), isOn: $recursive)
            Text(L10n.text("Deletion cannot be undone. Nodes are deleted individually; the operation stops on error and completed deletions are not rolled back."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { model.deletionTargets = [] }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Delete"), role: .destructive) { Task { await model.deleteNodes(recursive: recursive) } }
            }
        }.padding(24).frame(width: 480)
    }
}
