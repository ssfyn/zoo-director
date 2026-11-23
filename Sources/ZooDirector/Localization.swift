import Foundation

/// 以英文为源文案的翻译入口；模型保留英文状态，切换语言时无需重建连接。
@MainActor
enum L10n {
    /// 简体中文与英文目录，随应用资源一起发布。
    static let catalogs: [String: [String: String]] = ["en": load("en"), "zh-Hans": load("zh-Hans")]
    /// 只有嵌套错误才递归翻译，用户填写的连接名、路径和服务端数据保持原文。
    private static let nestedErrors: [String: Int] = [
        "Could not establish the SSH tunnel:\n{0}\nCheck the selected private key and passphrase. If the server fingerprint changed, verify it with your administrator before reconnecting.": 0,
        "{0}\nIf the connection was interrupted, refresh to check whether the node was created before retrying.": 0,
        "{0}\nIf the server may have received the write, reload the data to confirm the result.": 0,
        "Could not re-register compatibility watches: {0}": 0,
        "Live updates stopped: {0}; reconnect to continue": 0,
        "Confirmed deletion of {0} nodes; stopped at {1}: {2}\nBatch deletion is not atomic. If the connection was interrupted, the current request's result may be unknown. Refresh to confirm.": 2,
        "Watch registration failed: {0}": 0, "Directory refresh failed: {0}": 0,
        "Could not remove watch: {0}": 0, "Automatic reload failed: {0}": 0, "Connection failed: {0}": 0
    ]
    /// 已预编译的动态消息模板，优先匹配包含更多固定文字的完整消息。
    private static let patterns: [(key: String, regex: NSRegularExpression)] = {
        catalogs["en", default: [:]].keys.filter { $0.contains("{0}") }.sorted {
            $0.count > $1.count
        }.compactMap { key in
            guard let regex = makePattern(key)
            else { return nil }
            return (key, regex)
        }
    }()

    /// 只将目录中的编号占位符变为捕获组，其他符号均按普通文案处理。
    private static func makePattern(_ key: String) -> NSRegularExpression? {
        guard let placeholders = try? NSRegularExpression(pattern: #"\{\d+\}"#) else { return nil }
        var pattern = "^"
        var cursor = key.startIndex
        for match in placeholders.matches(in: key, range: NSRange(key.startIndex..., in: key)) {
            guard let range = Range(match.range, in: key) else { continue }
            pattern += NSRegularExpression.escapedPattern(for: String(key[cursor..<range.lowerBound])) + "(.*?)"
            cursor = range.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(for: String(key[cursor...])) + "$"
        return try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
    }

    /// 读取指定语言资源，缺失时保留源文案，避免影响业务操作。
    private static func load(_ language: String) -> [String: String] {
        guard let url = Bundle.module.url(forResource: language, withExtension: "json", subdirectory: "Localization"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    /// 在显示时读取可观察的语言选择，使菜单、弹窗和已有状态即时更新。
    static func text(_ source: String) -> String {
        text(source, language: LanguagePreferences.shared.resolvedLanguage)
    }

    /// 翻译固定标签或带路径、数量和嵌套错误的状态消息；不修改原始业务数据。
    static func text(_ source: String, language: String, depth: Int = 0) -> String {
        guard language == "zh-Hans", depth < 5 else { return source }
        if let value = catalogs[language]?[source] { return value }
        let range = NSRange(source.startIndex..., in: source)
        for template in patterns {
            guard let match = template.regex.firstMatch(in: source, range: range),
                  let translated = catalogs[language]?[template.key] else { continue }
            let arguments = (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: source) else { return "" }
                let value = String(source[range])
                return nestedErrors[template.key] == index - 1 ? text(value, language: language, depth: depth + 1) : value
            }
            return substitute(translated, arguments: arguments)
        }
        return source
    }

    /// 按模板一次性插入参数，避免参数中的花括号再次被当成占位符。
    static func substitute(_ template: String, arguments: [String]) -> String {
        let parts = template.components(separatedBy: "{")
        return parts.dropFirst().reduce(parts.first ?? "") { result, part in
            guard let end = part.firstIndex(of: "}"), let index = Int(part[..<end]), arguments.indices.contains(index)
            else { return result + "{" + part }
            return result + arguments[index] + part[part.index(after: end)...]
        }
    }
}
