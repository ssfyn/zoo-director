import SwiftUI

/// 语言首选项弹窗，选项立即生效且不关闭现有连接。
struct PreferencesView: View {
    /// 与主窗口和顶部菜单共享的语言设置。
    @Bindable var preferences: LanguagePreferences
    /// 关闭首选项弹窗的系统动作。
    @Environment(\.dismiss) private var dismiss

    /// 展示三个语言选项以及当前自动解析的语言。
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("首选项")).font(.title2.bold())
            Picker(L10n.text("语言"), selection: $preferences.selection) {
                Text(automaticTitle).tag(LanguageSelection.automatic)
                Text(verbatim: "English").tag(LanguageSelection.english)
                Text(verbatim: "简体中文").tag(LanguageSelection.simplifiedChinese)
            }.pickerStyle(.menu)
            Text(L10n.text("语言更改立即生效，并会在下次启动时保留。"))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
            .environment(\.locale, preferences.locale)
    }

    /// 自动选项明确显示当前系统语言对应的受支持语言。
    private var automaticTitle: String {
        let name = preferences.automaticLanguage == "zh-Hans" ? "简体中文" : "English"
        let template = L10n.catalogs[preferences.resolvedLanguage]?["自动（{0}）"] ?? "自动（{0}）"
        return L10n.substitute(template, arguments: [name])
    }
}
