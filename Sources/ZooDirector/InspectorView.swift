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
                Text(L10n.text("节点检查器")).font(.headline)
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
                            Button(L10n.text("重新读取")) { model.reloadInspector() }.disabled(model.dirty || model.saving)
                        }
                        if let snapshot = model.snapshot {
                            metadata(snapshot.stat)
                            Divider()
                            HStack {
                                Text(L10n.text("数据")).font(.headline)
                                Spacer()
                                Text(L10n.text("\(snapshot.data.count.formatted()) 字节")).font(.caption).foregroundStyle(.secondary)
                            }
                            dataEditor(snapshot)
                            if model.dirty {
                                Text(L10n.text("有未保存修改。保存前会检查服务端版本。"))
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            HStack {
                                Button(L10n.text("放弃修改")) { model.discard() }.disabled(!model.dirty || model.saving)
                                Spacer()
                                Button(L10n.text("保存…")) { confirmingSave = true }
                                    .buttonStyle(.borderedProminent).disabled(!model.dirty || model.saving || !model.connectionEstablished)
                            }
                        } else if !model.reading, model.inspectorNotice == nil {
                            Text(L10n.text("无法读取节点，请重新选择或刷新。")).foregroundStyle(.secondary)
                        }
                    }.padding(16)
                }
            } else {
                ContentUnavailableView(L10n.text("选择一个节点"), systemImage: "sidebar.right", description: Text(L10n.text("预览数据、版本与会话信息")))
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
            Text(L10n.text("二进制或超过 256 KiB 的内容仅显示前 512 字节的十六进制预览。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(snapshot.data.prefix(512).map { String(format: "%02x", $0) }.joined(separator: " "))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    /// 展示同一次读取获得的版本、时间和节点类型。
    private func metadata(_ stat: NodeStat) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            entry(L10n.text("类型"), stat.isEphemeral ? L10n.text("临时节点") : L10n.text("非临时节点"))
            entry(L10n.text("数据版本"), String(stat.version))
            entry(L10n.text("子节点"), String(stat.childCount))
            entry(L10n.text("创建时间"), date(stat.created))
            entry(L10n.text("修改时间"), date(stat.modified))
            entry(L10n.text("会话"), stat.isEphemeral ? String(format: "0x%llx", stat.ephemeralOwner) : "—")
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
