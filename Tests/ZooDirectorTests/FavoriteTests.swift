import XCTest
@testable import ZooDirector

/// 验证收藏在连接之间隔离，并在重启和目录导航时保持正确状态。
@MainActor
final class FavoriteTests: XCTestCase {
    /// 等待目录或节点读取结束，让异步演示服务有机会发布结果。
    private func waitUntilIdle(_ model: BrowserModel) async throws {
        for _ in 0..<200 {
            if !model.loading && !model.reading { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("浏览状态未在预期时间内完成加载")
    }

    /// 相同名称和地址的真实连接仍按稳定标识隔离收藏，移除也不会影响其他连接。
    func testConnectionIsolationAndPersistence() async throws {
        let suite = "ZooDirector.Favorites.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ConnectionProfile(name: "相同名称", endpoint: "localhost:2181")
        let second = ConnectionProfile(name: first.name, endpoint: first.endpoint)
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "zoodirector.connections")
        defaults.set(try JSONEncoder().encode([
            first.id.uuidString: ["/services"], second.id.uuidString: ["/services", "/configuration"]
        ]), forKey: "zoodirector.favorites")
        let model = BrowserModel(defaults: defaults, serviceFactory: { _ in DemoService() })
        XCTAssertTrue(model.favorites.isEmpty)
        model.activeID = first.id
        XCTAssertEqual(model.favorites, ["/services"])
        model.removeFavorite("/services")
        model.activeID = second.id
        XCTAssertEqual(model.favorites, ["/services", "/configuration"])
        let restored = BrowserModel(defaults: defaults, serviceFactory: { _ in DemoService() })
        restored.activeID = first.id
        XCTAssertTrue(restored.favorites.isEmpty)
        restored.activeID = second.id
        XCTAssertEqual(restored.favorites, ["/services", "/configuration"])
    }

    /// 收藏针对显示目录，重复切换不会生成重复路径，真实配置重启后也可恢复。
    func testToggleAndPersistence() async throws {
        let suite = "ZooDirector.Favorites.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BrowserModel(defaults: defaults, serviceFactory: { _ in DemoService() })
        model.toggleCurrentFavorite()
        XCTAssertTrue(model.favorites.isEmpty)
        if model.profiles.isEmpty { model.addConnection(name: "隔离测试", endpoint: "localhost:2181") }
        model.connect(try XCTUnwrap(model.profiles.first))
        try await waitUntilIdle(model)
        model.navigate("/services")
        try await waitUntilIdle(model)
        model.pathInput = "/unsubmitted"
        model.toggleCurrentFavorite()
        XCTAssertEqual(model.favorites, ["/services"])
        model.toggleCurrentFavorite()
        XCTAssertTrue(model.favorites.isEmpty)
        model.toggleCurrentFavorite()
        let restored = BrowserModel(defaults: defaults, serviceFactory: { _ in DemoService() })
        restored.connect(try XCTUnwrap(restored.profiles.first))
        try await waitUntilIdle(restored)
        XCTAssertEqual(restored.favorites, ["/services"])
        restored.navigate(try XCTUnwrap(restored.favorites.first))
        try await waitUntilIdle(restored)
        XCTAssertEqual(restored.path, "/services")
        XCTAssertTrue(restored.isCurrentPathFavorite)
    }

    /// 收藏导航必须保护编辑内容，非法路径和加载中的目录不能加入收藏。
    func testNavigationProtectionAndInvalidDirectory() async throws {
        let suite = "ZooDirector.Favorites.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BrowserModel(defaults: defaults, serviceFactory: { _ in DemoService() })
        if model.profiles.isEmpty { model.addConnection(name: "隔离测试", endpoint: "localhost:2181") }
        model.connect(try XCTUnwrap(model.profiles.first))
        try await waitUntilIdle(model)
        model.toggleCurrentFavorite()
        model.navigate("/services")
        try await waitUntilIdle(model)
        model.select("/services/api")
        try await waitUntilIdle(model)
        model.editor += "修改"
        XCTAssertTrue(model.dirty)
        model.navigate(try XCTUnwrap(model.favorites.first))
        XCTAssertEqual(model.path, "/services")
        XCTAssertNotNil(model.error)
        model.discard()
        model.error = nil
        model.navigate("/invalid/")
        XCTAssertEqual(model.path, "/services")
        XCTAssertNotNil(model.error)
        model.navigate("/configuration")
        XCTAssertFalse(model.canFavoriteCurrentPath)
        model.toggleCurrentFavorite()
        XCTAssertEqual(model.favorites, ["/"])
        try await waitUntilIdle(model)
    }
}
