import Foundation
import Observation

/// 持久化的语言选项，原始值不随界面语言变化。
enum LanguageSelection: String, CaseIterable, Identifiable {
    /// 优先使用系统语言，不支持时使用英文。
    case automatic
    /// 始终使用英文。
    case english
    /// 始终使用简体中文。
    case simplifiedChinese

    /// 下拉选项的稳定标识。
    var id: String { rawValue }

    /// 根据首选系统语言解析实际语言，不支持的语言统一回退为英文。
    func resolvedLanguage(preferredLanguages: [String]) -> String {
        switch self {
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .automatic:
            let parts = (preferredLanguages.first ?? "en").lowercased()
                .replacingOccurrences(of: "_", with: "-").split(separator: "-")
            guard parts.first == "zh" else { return "en" }
            if parts.contains("hant") { return "en" }
            if parts.contains("hans") { return "zh-Hans" }
            if parts.contains(where: { ["tw", "hk", "mo"].contains(String($0)) }) { return "en" }
            return "zh-Hans"
        }
    }
}

/// 为窗口和菜单共享语言状态；切换时保留已有连接、编辑器和表单状态。
@MainActor @Observable
final class LanguagePreferences {
    /// 正式应用使用同一份可观察的语言设置。
    static let shared = LanguagePreferences()
    /// 语言选项的持久化键。
    static let storageKey = "zoodirector.language"
    /// 用于持久化选择的配置域，可在测试中替换。
    private let defaults: UserDefaults
    /// 注入的系统语言列表，正式应用每次解析时读取系统当前值。
    private let preferredLanguages: [String]?
    /// 当前选项，默认自动；修改后立即持久化。
    var selection: LanguageSelection {
        didSet { defaults.set(selection.rawValue, forKey: Self.storageKey) }
    }

    /// 恢复有效的语言选择，未知或缺失值按自动处理。
    init(defaults: UserDefaults = .standard, preferredLanguages: [String]? = nil) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        selection = defaults.string(forKey: Self.storageKey).flatMap(LanguageSelection.init(rawValue:)) ?? .automatic
    }

    /// 自动选项当前跟随的实际语言，用于下拉菜单中的括号提示。
    var automaticLanguage: String {
        LanguageSelection.automatic.resolvedLanguage(preferredLanguages: preferredLanguages ?? Locale.preferredLanguages)
    }

    /// 当前实际使用的受支持语言。
    var resolvedLanguage: String {
        selection.resolvedLanguage(preferredLanguages: preferredLanguages ?? Locale.preferredLanguages)
    }

    /// 将显式语言选择传递给 SwiftUI 和日期格式化器。
    var locale: Locale { Locale(identifier: resolvedLanguage) }
}
