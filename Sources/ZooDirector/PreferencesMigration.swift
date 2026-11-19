import Foundation

/// 将更名前的连接与收藏复制到新命名空间，保留原数据作为兼容备份。
enum PreferencesMigration {
    /// 仅补齐尚不存在的新键；测试可注入旧域，避免访问用户的真实配置。
    static func migrate(into defaults: UserDefaults, legacyDomain: [String: Any]? = nil) {
        let previous = legacyDomain ?? (defaults === UserDefaults.standard
            ? defaults.persistentDomain(forName: "app.canopy.zookeeper") ?? [:] : [:])
        for suffix in ["connections", "favorites"] {
            let newKey = "zoodirector.\(suffix)"
            let oldKey = "canopy.\(suffix)"
            guard defaults.object(forKey: newKey) == nil else { continue }
            if let value = defaults.data(forKey: oldKey) ?? previous[oldKey] as? Data {
                defaults.set(value, forKey: newKey)
            }
        }
    }
}
