import XCTest
@testable import ZooDirector

/// 验证应用更名时保留连接和收藏，且不会覆盖更名后的用户修改。
@MainActor
final class PreferencesMigrationTests: XCTestCase {
    /// 从旧应用域迁移配置后，浏览模型可以恢复连接及其收藏。
    func testMigratingLegacyDomainRestoresProfilesAndFavorites() throws {
        let suite = "ZooDirector.Migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ConnectionProfile(name: "旧连接", endpoint: "localhost:2181")
        let connections = try JSONEncoder().encode([profile])
        let favorites = try JSONEncoder().encode([profile.id.uuidString: ["/services"]])
        PreferencesMigration.migrate(into: defaults, legacyDomain: [
            "canopy.connections": connections, "canopy.favorites": favorites
        ])
        let model = BrowserModel(defaults: defaults)
        XCTAssertEqual(model.profiles, [profile])
        model.activeID = profile.id
        XCTAssertEqual(model.favorites, ["/services"])
        XCTAssertFalse(model.connecting)
    }

    /// 已清空的新配置同样属于有效修改，重复迁移不能复活旧连接。
    func testExistingNewValuesAreNeverOverwritten() throws {
        let suite = "ZooDirector.Migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let empty = try JSONEncoder().encode([ConnectionProfile]())
        defaults.set(empty, forKey: "zoodirector.connections")
        let old = try JSONEncoder().encode([ConnectionProfile(name: "旧连接", endpoint: "localhost:2181")])
        let legacy: [String: Any] = ["canopy.connections": old]
        PreferencesMigration.migrate(into: defaults, legacyDomain: legacy)
        PreferencesMigration.migrate(into: defaults, legacyDomain: legacy)
        XCTAssertEqual(defaults.data(forKey: "zoodirector.connections"), empty)
    }

    /// 同一配置域中的旧键优先于旧应用域，迁移保留原始备份。
    func testLocalLegacyKeysTakePrecedence() throws {
        let suite = "ZooDirector.Migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = Data("本地配置".utf8)
        defaults.set(local, forKey: "canopy.connections")
        PreferencesMigration.migrate(into: defaults, legacyDomain: ["canopy.connections": Data()])
        XCTAssertEqual(defaults.data(forKey: "zoodirector.connections"), local)
        XCTAssertEqual(defaults.data(forKey: "canopy.connections"), local)
    }
}
