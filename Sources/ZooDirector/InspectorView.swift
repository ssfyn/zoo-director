import SwiftUI

/// 选中节点的数据编辑与元信息检查器。
struct InspectorView: View {
    /// 当前浏览状态。
    @Bindable var model: BrowserModel
    /// 保存确认框的可见状态。
    @Binding var confirmingSave: Bool

    /// 根据加载状态、数据类型和选择情况显示详情。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("Node Inspector")).font(.headline)
                Spacer()
                if model.reading || model.saving { ProgressView().controlSize(.small) }
            }.padding(16)
            Divider()
            if let selected = model.inspectedPath {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(selected, systemImage: "doc.text")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let notice = model.inspectorNotice {
                            Text(L10n.text(notice)).font(.caption).foregroundStyle(.orange)
                            Button(L10n.text("Reload")) { model.reloadInspector() }.disabled(model.dirty || model.saving)
                        }
                        if let snapshot = model.snapshot {
                            metadata(snapshot.stat)
                            Divider()
                            HStack {
                                Text(L10n.text("Data")).font(.headline)
                                Spacer()
                                Text(L10n.text("\(snapshot.data.count.formatted()) bytes")).font(.caption).foregroundStyle(.secondary)
                            }
                            dataEditor(snapshot)
                            if model.dirty {
                                Text(L10n.text("Unsaved changes. The server version will be checked before saving."))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            HStack {
                                Button(L10n.text("Discard Changes")) { model.discard() }.disabled(!model.dirty || model.saving)
                                Spacer()
                                Button(L10n.text("Save…")) { confirmingSave = true }
                                    .buttonStyle(.borderedProminent).disabled(!model.dirty || model.saving || !model.connectionEstablished)
                            }
                        } else if !model.reading, model.inspectorNotice == nil {
                            Text(L10n.text("Could not read the node. Select it again or refresh.")).foregroundStyle(.secondary)
                        }
                    }.padding(16)
                }
            } else {
                ContentUnavailableView(L10n.text("Select a Node"), systemImage: "sidebar.right", description: Text(L10n.text("Preview data, versions, and session information")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(.background)
    }

    /// 区分可编辑文本和只读的二进制或大数据预览。
    @ViewBuilder private func dataEditor(_ snapshot: NodeSnapshot) -> some View {
        if model.editable {
            TextEditor(text: $model.editor)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(8)
                .frame(minHeight: 260, maxHeight: 450)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                .disabled(model.saving)
        } else {
            Text(L10n.text("For binary data or content over 256 KiB, only the first 512 bytes are shown as a read-only hex preview."))
                .font(.caption).foregroundStyle(.secondary)
            Text(snapshot.data.prefix(512).map { String(format: "%02x", $0) }.joined(separator: " "))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    /// 展示同一次读取获得的版本、时间和节点类型。
    private func metadata(_ stat: NodeStat) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            entry(L10n.text("Type"), stat.isEphemeral ? L10n.text("Ephemeral node") : L10n.text("Persistent node"))
            entry(L10n.text("Data version"), String(stat.version))
            entry(L10n.text("Children"), String(stat.childCount))
            entry(L10n.text("Created"), date(stat.created))
            entry(L10n.text("Modified"), date(stat.modified))
            entry(L10n.text("Session"), stat.isEphemeral ? String(format: "0x%llx", stat.ephemeralOwner) : "—")
        }.font(.caption)
    }

    /// 绘制一行标签与可复制的值。
    private func entry(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    /// 按系统本地时间格式化服务端毫秒时间戳。
    private func date(_ timestamp: Int64) -> String {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            .formatted(.dateTime.locale(LanguagePreferences.shared.locale))
    }
}
