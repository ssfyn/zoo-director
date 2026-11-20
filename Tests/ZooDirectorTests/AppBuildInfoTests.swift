import XCTest
@testable import ZooDirector

/// 验证关于窗口使用构建时的展示版本，调试启动也有稳定的开发标记。
@MainActor
final class AppBuildInfoTests: XCTestCase {
    /// 没有应用清单时显示 dev，不向用户展示默认内部构建号。
    func testDevelopmentFallback() {
        let info = AppBuildInfo(info: [:])
        XCTAssertEqual(info.displayVersion, "dev")
        XCTAssertEqual(info.channel, "dev")
        XCTAssertEqual(info.aboutOptions[.applicationVersion] as? String, "dev")
        XCTAssertEqual(info.aboutOptions[.version] as? String, "")
    }

    /// 正式版本、预发布标签与渠道均来自包内信息，不依赖联网查询。
    func testReleaseAndStoreMetadata() {
        for channel in ["github", "appstore"] {
            let info = AppBuildInfo(info: ["ZooDirectorDisplayVersion": "1.0.0", "CFBundleVersion": "42.1",
                                           "ZooDirectorDistributionChannel": channel])
            XCTAssertEqual(info.aboutOptions[.applicationVersion] as? String, "1.0.0")
            XCTAssertEqual(info.aboutOptions[.version] as? String, "42.1")
            XCTAssertEqual(info.channel, channel)
        }
        let prerelease = AppBuildInfo(info: ["ZooDirectorDisplayVersion": "1.1.0-beta.1", "CFBundleShortVersionString": "1.1.0"])
        XCTAssertEqual(prerelease.displayVersion, "1.1.0-beta.1")
    }
}
