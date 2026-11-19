import SwiftUI

/// 树表保留时间列与检查器，实际行复用和键盘操作交给原生表格。
struct NodeTreeView: View {
    /// 当前窗口的树、选择及编辑状态。
    @Bindable var model: BrowserModel

    /// 将完整展开结构交给系统表格，节点计数统一由窗口状态栏显示。
    var body: some View {
        NativeNodeTable(model: model, nodes: [], treeRows: model.tree.rows, treeMode: true,
                        revision: model.tree.revision, selectedPath: model.selection, blocked: model.dirty || model.saving, selectedPaths: model.selectedPaths)
    }
}
