import Foundation

/// 更换应用标识时复制连接、收藏与语言，保留旧配置作为兼容备份。
enum PreferencesMigration {
    /// 仅补齐缺失的新键，优先使用上一版配置；测试可注入旧域避免读取真实偏好。
    static func migrate(into defaults: UserDefaults, legacyDomain: [String: Any]? = nil,
                        previousDomain: [String: Any]? = nil) {
        let previous = previousDomain ?? (defaults === UserDefaults.standard
            ? defaults.persistentDomain(forName: "app.zoodirector.zookeeper") ?? [:] : [:])
        let legacy = legacyDomain ?? (defaults === UserDefaults.standard
            ? defaults.persistentDomain(forName: "app.canopy.zookeeper") ?? [:] : [:])
        for suffix in ["connections", "favorites", "language"] {
            let newKey = "zoodirector.\(suffix)"
            guard defaults.object(forKey: newKey) == nil else { continue }
            if let value = previous[newKey] {
                defaults.set(value, forKey: newKey)
            } else if suffix != "language" {
                let oldKey = "canopy.\(suffix)"
                if let value = defaults.data(forKey: oldKey) ?? legacy[oldKey] as? Data {
                    defaults.set(value, forKey: newKey)
                }
            }
        }
    }
}
