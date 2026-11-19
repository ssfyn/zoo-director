import XCTest
@testable import ZooDirector

/// 验证连接编辑、删除及持久化不会破坏其他连接和未保存内容。
@MainActor
final class ConnectionTests: XCTestCase {
    /// 编辑保留标识和收藏，删除只清理目标配置与收藏。
    func testEditingAndDeletingPersistedConnection() throws {
        let suite = "ZooDirector.Connections.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ConnectionProfile(name: "第一台", endpoint: "localhost:2181")
        let second = ConnectionProfile(name: "第二台", endpoint: "localhost:2182")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "zoodirector.connections")
        defaults.set(try JSONEncoder().encode([
            first.id.uuidString: ["/services"], second.id.uuidString: ["/configuration"]
        ]), forKey: "zoodirector.favorites")
        let model = BrowserModel(defaults: defaults)
        XCTAssertTrue(model.updateConnection(first, name: "新名称", endpoint: "localhost:2183"))
        let restored = BrowserModel(defaults: defaults)
        let edited = try XCTUnwrap(restored.profiles.first { $0.id == first.id })
        XCTAssertEqual(edited.name, "新名称")
        XCTAssertEqual(edited.endpoint, "localhost:2183")
        restored.activeID = first.id
        XCTAssertEqual(restored.favorites, ["/services"])
        model.deleteConnection(first)
        let deleted = BrowserModel(defaults: defaults)
        XCTAssertFalse(deleted.profiles.contains { $0.id == first.id })
        deleted.activeID = first.id
        XCTAssertTrue(deleted.favorites.isEmpty)
        deleted.activeID = second.id
        XCTAssertEqual(deleted.favorites, ["/configuration"])
        XCTAssertTrue(deleted.profiles.contains(second))
    }

    /// 当前连接存在未保存内容或正在写入时禁止关闭及删除。
    func testActiveConnectionProtectionAndDeletion() throws {
        let suite = "ZooDirector.Connections.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ConnectionProfile(name: "测试", endpoint: "localhost:2181")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "zoodirector.connections")
        let model = BrowserModel(defaults: defaults)
        model.selectConnection(profile)
        model.activeID = profile.id
        model.snapshot = NodeSnapshot(data: Data("原文".utf8), stat: NodeStat())
        model.editor = "修改"
        XCTAssertFalse(model.updateConnection(profile, name: "修改", endpoint: "localhost:2182"))
        model.disconnect()
        XCTAssertEqual(model.activeID, profile.id)
        XCTAssertTrue(model.dirty)
        model.deleteConnection(profile)
        XCTAssertTrue(model.profiles.contains(profile))
        model.discard()
        model.saving = true
        model.deleteConnection(profile)
        XCTAssertTrue(model.profiles.contains(profile))
        model.saving = false
        model.deleteConnection(profile)
        XCTAssertNil(model.activeID)
        XCTAssertNil(model.selectedProfile)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.connectionEstablished)
        XCTAssertFalse(model.loading)
    }
}
