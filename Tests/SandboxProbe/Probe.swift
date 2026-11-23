import Foundation
import Security

/// 为实际隧道源码提供隔离的测试错误类型。
enum ZooKeeperError: LocalizedError {
    /// 测试失败时供命令行输出的说明。
    case message(String)
    /// 保留诊断说明，不输出任何测试密钥内容。
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
/// 使用固定语言，避免读取主应用配置。
@MainActor struct LanguagePreferences {
    /// 隧道测试共用的固定语言实例。
    static let shared = LanguagePreferences()
    /// 辅助程序使用英文，避免依赖用户系统语言。
    let resolvedLanguage = "en"
}
/// 在真实沙箱下运行实际的文件授权、钥匙串和隧道代码。
@main enum Probe {
    /// 仅连接参数指定的本机测试服务，并在退出时删除独立钥匙串条目。
    @MainActor static func main() async {
        do {
            guard FileManager.default.homeDirectoryForCurrentUser.path.contains("/Containers/") else {
                throw ZooKeeperError.message("App Sandbox did not activate")
            }
            guard (try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))) == nil else {
                throw ZooKeeperError.message("Sandbox allowed an unauthorized external file read")
            }
            let resources = Bundle.main.resourceURL!
            let config = SSHConfiguration(host: "127.0.0.1", port: Int(CommandLine.arguments[1])!,
                username: CommandLine.arguments[2], identityFile: "fixture",
                identityBookmark: try SSHPrivateKey.bookmark(for: resources.appendingPathComponent("identity")))
            let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: resources.appendingPathComponent("known_hosts"), to: knownHosts)
            defer { try? FileManager.default.removeItem(at: knownHosts) }
            let tunnel = try SSHTunnel(knownHostsURL: knownHosts)
            defer { tunnel.stop() }
            let endpoint = try await tunnel.start(configuration: config, endpoint: CommandLine.arguments[3])
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://" + endpoint)!)
            guard String(decoding: data, as: UTF8.self) == "sandbox-tunnel-ok" else {
                throw ZooKeeperError.message("Forwarded response did not match")
            }
            let store = KeychainDigestPasswordStore()
            let id = UUID()
            try store.save("fixture-only", id: id)
            defer { try? store.remove(id) }
            guard try store.load(id) == "fixture-only" else { throw ZooKeeperError.message("Keychain failed") }
            UserDefaults.standard.set(id.uuidString, forKey: "probe-value")
            defer { UserDefaults.standard.removeObject(forKey: "probe-value") }
            guard UserDefaults.standard.string(forKey: "probe-value") == id.uuidString else {
                throw ZooKeeperError.message("Preferences failed")
            }
            print("PASS real App Sandbox: bookmark, system SSH, TCP forwarding and Keychain")
        } catch {
            FileHandle.standardError.write(Data(("FAIL " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
