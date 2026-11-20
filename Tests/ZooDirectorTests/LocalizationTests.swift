import XCTest
import AppKit
@testable import ZooDirector

/// 验证语言回退、持久化以及动态状态翻译不会改动用户输入。
@MainActor
final class LocalizationTests: XCTestCase {
    /// 自动仅跟随第一系统语言，繁体中文和其他不支持语言回退英文。
    func testAutomaticLanguageResolution() {
        for value in ["zh-Hans", "zh-Hans-CN", "zh-CN", "zh-SG", "zh"] {
            XCTAssertEqual(LanguageSelection.automatic.resolvedLanguage(preferredLanguages: [value]), "zh-Hans")
        }
        for value in ["en", "en-GB", "ja-JP", "fr-FR", "zh-Hant", "zh-TW", "zh-HK"] {
            XCTAssertEqual(LanguageSelection.automatic.resolvedLanguage(preferredLanguages: [value, "zh-Hans"]), "en")
        }
        XCTAssertEqual(LanguageSelection.automatic.resolvedLanguage(preferredLanguages: []), "en")
    }

    /// 显式选择优先于系统语言，重启模型后恢复相同选项。
    func testDefaultAndPersistedSelection() throws {
        let suite = "ZooDirector.Language.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LanguagePreferences(defaults: defaults, preferredLanguages: ["zh-Hans"])
        XCTAssertEqual(preferences.selection, .automatic)
        XCTAssertEqual(preferences.automaticLanguage, "zh-Hans")
        preferences.selection = .english
        XCTAssertEqual(preferences.resolvedLanguage, "en")
        XCTAssertEqual(LanguagePreferences(defaults: defaults).selection, .english)
        preferences.selection = .simplifiedChinese
        XCTAssertEqual(preferences.resolvedLanguage, "zh-Hans")
        defaults.set("unknown", forKey: LanguagePreferences.storageKey)
        XCTAssertEqual(LanguagePreferences(defaults: defaults).selection, .automatic)
    }

    /// 两种语言资源键完整对应，避免发布时只打包了部分标签。
    func testBothCatalogsAreComplete() throws {
        let english = try XCTUnwrap(L10n.catalogs["en"])
        let chinese = try XCTUnwrap(L10n.catalogs["zh-Hans"])
        XCTAssertGreaterThan(english.count, 200)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(value, key)
            XCTAssertNotNil(chinese[key])
            XCTAssertFalse(key.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, key)
        }
    }

    /// 所有动态模板从英文源文案匹配中文，参数中的非拉丁文字和花括号保持原样。
    func testEveryDynamicTemplateUsesEnglishSource() throws {
        let english = try XCTUnwrap(L10n.catalogs["en"])
        let chinese = try XCTUnwrap(L10n.catalogs["zh-Hans"])
        let arguments = (0..<3).map { "/参数\($0)/{1}" }
        for key in english.keys where key.contains("{0}") {
            let source = L10n.substitute(key, arguments: arguments)
            let translated = L10n.substitute(try XCTUnwrap(chinese[key]), arguments: arguments)
            XCTAssertEqual(L10n.text(source, language: "zh-Hans"), translated, key)
            XCTAssertEqual(L10n.text(source, language: "en"), source, key)
        }
    }

    /// 已存在的模型状态按显示时的语言翻译，无需重建连接或清空编辑。
    func testLanguageChangesApplyToExistingMessages() {
        let shared = LanguagePreferences.shared
        let previous = shared.selection
        defer { shared.selection = previous }
        let message = "Scanned 12 directories"
        shared.selection = .english
        XCTAssertEqual(L10n.text(message), "Scanned 12 directories")
        shared.selection = .simplifiedChinese
        XCTAssertEqual(L10n.text(message), "已扫描 12 个目录")
    }

    /// 动态模板保留数量、非拉丁路径及恰好与界面标签同名的连接名。
    func testDynamicMessagesPreserveUserValues() {
        XCTAssertEqual(L10n.text("Parent: /服务/{0}", language: "zh-Hans"), "父节点：/服务/{0}")
        let source = "The local configuration and favorites for “Name” will be deleted and its session closed. Other sessions will remain connected. ZooKeeper server data will not be affected."
        XCTAssertTrue(L10n.text(source, language: "zh-Hans").contains("“Name”"))
        let summary = "Scanned 20 directories · Skipped 2 unreadable directories · Limit reached; results incomplete"
        XCTAssertEqual(L10n.text(summary, language: "zh-Hans"),
                       "扫描 20 个目录 · 跳过 2 个不可读取目录 · 已达上限，结果不完整")
    }

    /// 嵌套错误和未知系统消息可共存，原始业务数据保持不变。
    func testNestedErrorsAndUnknownMessages() {
        let message = "Connection failed: The node does not exist. Refresh the parent node."
        XCTAssertEqual(L10n.text(message, language: "zh-Hans"), "连接失败：节点不存在，请刷新父节点。")
        XCTAssertEqual(L10n.text("OS error 42", language: "zh-Hans"), "OS error 42")
        XCTAssertEqual(L10n.text("Unknown source text", language: "fr"), "Unknown source text")
        XCTAssertEqual(L10n.substitute("{0} / {1}", arguments: ["{1}", "原文"]), "{1} / 原文")
    }

    /// 系统菜单容器和动作标签双向切换，原始动作及快捷键保持不变。
    func testNativeMenuTitlesFollowLanguage() {
        let shared = LanguagePreferences.shared
        let previous = shared.selection
        defer { shared.selection = previous }
        let menu = NSMenu(title: "编辑")
        let copy = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(copy)
        shared.selection = .english
        NativeMenuLocalization.refresh(menu)
        XCTAssertEqual(menu.title, "Edit")
        XCTAssertEqual(copy.title, "Copy")
        shared.selection = .simplifiedChinese
        NativeMenuLocalization.refresh(menu)
        XCTAssertEqual(menu.title, "编辑")
        XCTAssertEqual(copy.title, "复制")
        XCTAssertEqual(copy.action, #selector(NSText.copy(_:)))
        XCTAssertEqual(copy.keyEquivalent, "c")
    }
}
