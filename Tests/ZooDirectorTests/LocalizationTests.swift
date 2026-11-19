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
            XCTAssertEqual(chinese[key], key)
        }
    }

    /// 已存在的模型状态按显示时的语言翻译，无需重建连接或清空编辑。
    func testLanguageChangesApplyToExistingMessages() {
        let shared = LanguagePreferences.shared
        let previous = shared.selection
        defer { shared.selection = previous }
        let message = "已扫描 12 个目录"
        shared.selection = .english
        XCTAssertEqual(L10n.text(message), "Scanned 12 directories")
        shared.selection = .simplifiedChinese
        XCTAssertEqual(L10n.text(message), message)
    }

    /// 动态模板保留数量、非拉丁路径及恰好与界面标签同名的连接名。
    func testDynamicMessagesPreserveUserValues() {
        XCTAssertEqual(L10n.text("父节点：/服务/{0}", language: "en"), "Parent: /服务/{0}")
        let source = "将删除“名称”的本机配置和收藏。该连接的会话会关闭，其他会话继续保持。ZooKeeper 服务端数据不受影响。"
        XCTAssertTrue(L10n.text(source, language: "en").contains("“名称”"))
        let summary = "扫描 20 个目录 · 跳过 2 个不可读取目录 · 已达上限，结果不完整"
        XCTAssertEqual(L10n.text(summary, language: "en"),
                       "Scanned 20 directories · Skipped 2 unreadable directories · Limit reached; results incomplete")
    }

    /// 嵌套错误和未知系统消息可共存，原始业务数据保持不变。
    func testNestedErrorsAndUnknownMessages() {
        let message = "连接失败：节点不存在，请刷新父节点。"
        XCTAssertEqual(L10n.text(message, language: "en"), "Connection failed: The node does not exist. Refresh the parent node.")
        XCTAssertEqual(L10n.text("OS error 42", language: "en"), "OS error 42")
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
