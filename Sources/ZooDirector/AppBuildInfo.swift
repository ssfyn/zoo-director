import AppKit

/// 统一读取包内构建信息，直接通过 Xcode 或 SwiftPM 启动时显示开发版本。
struct AppBuildInfo {
    /// 展示版本允许 dev 和预发布标记，不写入 Apple 的数字版本字段。
    let displayVersion: String
    /// 用于区分同一发行版本下的多次构建。
    let buildNumber: String
    /// 构建渠道预留给后续 App Store 分发。
    let channel: String

    /// 从可注入的清单读取版本，未打包的调试程序安全回退到 dev。
    init(info: [String: Any]) {
        displayVersion = info["ZooDirectorDisplayVersion"] as? String ?? "dev"
        buildNumber = info["CFBundleVersion"] as? String ?? "1"
        channel = info["ZooDirectorDistributionChannel"] as? String ?? "dev"
    }

    /// 保留系统关于窗口，开发版本不额外展示无意义的默认构建号。
    var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationVersion: displayVersion, .version: displayVersion == "dev" ? "" : buildNumber]
    }

    /// 使用构建时注入的信息显示关于窗口，无需连接 GitHub。
    @MainActor static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: AppBuildInfo(info: Bundle.main.infoDictionary ?? [:]).aboutOptions)
    }
}
