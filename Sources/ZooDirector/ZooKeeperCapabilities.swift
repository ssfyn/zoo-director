import Foundation

/// 根据明确的服务端版本选择协议，未知能力时只使用旧版兼容指令。
enum ZooKeeperWatchMode: Sendable {
    /// 所有支持普通监听的 ZooKeeper 均可使用，事件后重新注册。
    case standard
    /// ZooKeeper 3.6 起支持的持久非递归监听。
    case persistent

    /// 状态栏显示当前实际采用的监听方式。
    var status: String {
        self == .persistent ? "Live updates" : "Live updates (compatibility mode)"
    }

    /// 只在版本明确满足要求时使用新协议，禁止通过不支持的指令试探主会话。
    static func parse(serverInfo: String) -> ZooKeeperWatchMode {
        let pattern = #"(?i)zookeeper version:\s*(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: serverInfo, range: NSRange(serverInfo.startIndex..., in: serverInfo)),
              let majorRange = Range(match.range(at: 1), in: serverInfo),
              let minorRange = Range(match.range(at: 2), in: serverInfo),
              let major = Int(serverInfo[majorRange]), let minor = Int(serverInfo[minorRange]) else { return .standard }
        return major > 3 || (major == 3 && minor >= 6) ? .persistent : .standard
    }

    /// 独立连接只读查询版本；四字命令禁用或查询失败时安全回退到普通监听。
    static func detect(endpoint: String) async -> ZooKeeperWatchMode {
        guard let probe = try? ZooKeeperTransport(endpoint: endpoint) else { return .standard }
        defer { probe.cancel() }
        do {
            try await probe.start(timeout: 2)
            try await probe.send(Data("srvr".utf8))
            let info = try await probe.serverInfo()
            return parse(serverInfo: info)
        } catch { return .standard }
    }
}
