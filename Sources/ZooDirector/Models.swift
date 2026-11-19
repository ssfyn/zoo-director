import Foundation

/// 连接配置，不保存认证凭据。
struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    /// 配置的稳定标识。
    var id = UUID()
    /// 用户可选填写的名称，留空时仍保存为空。
    var name: String
    /// 服务器地址，首版只接受单个主机与端口。
    var endpoint: String
    /// 仅用于识别并过滤旧版本的演示配置，不再提供演示连接。
    var isDemo = false
    /// 可选的 SSH 隧道配置，旧版本保存的连接默认直连。
    var ssh: SSHConfiguration?

    /// 名称留空时以服务器地址显示，避免侧栏、加载页和删除确认出现空标题。
    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? endpoint : name
    }
}

/// 节点的版本和服务端元信息。
struct NodeStat: Sendable {
    /// 创建事务编号。
    var createdZXID: Int64 = 0
    /// 最后修改事务编号。
    var modifiedZXID: Int64 = 0
    /// 创建时间的毫秒时间戳。
    var created: Int64 = 0
    /// 修改时间的毫秒时间戳。
    var modified: Int64 = 0
    /// 数据版本，写入时用于乐观锁。
    var version: Int32 = 0
    /// 子节点版本。
    var childVersion: Int32 = 0
    /// 权限版本。
    var aclVersion: Int32 = 0
    /// 客户端可见的临时节点所属会话，其他节点为零。
    var ephemeralOwner: Int64 = 0
    /// 数据字节数。
    var dataLength: Int32 = 0
    /// 直接子节点数量。
    var childCount: Int32 = 0
    /// 最后一次子节点修改事务编号。
    var childrenZXID: Int64 = 0

    /// 根据服务端返回的所属会话判断是否为临时节点。
    var isEphemeral: Bool { ephemeralOwner != 0 }
}

/// 一次读取取得的数据与对应版本。
struct NodeSnapshot: Sendable {
    /// 原始字节，禁止对无法解码的数据进行隐式转换。
    var data: Data
    /// 与原始数据对应的服务端状态。
    var stat: NodeStat
}

/// 可替换的异步访问接口，界面不依赖具体传输实现。
protocol ZooKeeperService: Sendable {
    /// 读取指定节点的直接子节点名称。
    func children(_ path: String) async throws -> [String]
    /// 只读取节点元信息，不下载数据内容。
    func stat(_ path: String) async throws -> NodeStat
    /// 读取节点内容及版本信息。
    func read(_ path: String) async throws -> NodeSnapshot
    /// 按读取到的版本更新内容，防止覆盖其他客户端的修改。
    func write(_ path: String, data: Data, version: Int32) async throws
    /// 创建节点，默认使用开放权限；临时节点随当前会话结束删除。
    func create(_ path: String, data: Data, ephemeral: Bool) async throws
    /// 使用已读取的数据版本删除叶节点，禁止隐式递归删除。
    func delete(_ path: String, version: Int32) async throws
    /// 订阅当前连接的节点变化与监听状态。
    func watchEvents() async -> AsyncStream<WatchEvent>
    /// 更新某个界面关注者的非递归监听范围，代次用于忽略迟到的旧请求。
    func watch(_ paths: Set<String>, owner: UUID, revision: UInt64) async
    /// 主动关闭连接并释放后台任务。
    func close() async
}

/// 面向用户的连接与协议错误。
enum ZooKeeperError: LocalizedError {
    case message(String)
    case server(Int32)

    /// 将协议错误码转换为可操作的中文提示。
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .server(-101): return "节点不存在，请刷新父节点。"
        case .server(-102): return "没有访问权限。首版尚未支持认证。"
        case .server(-103): return "数据已被其他客户端修改。请重新读取后再编辑。"
        case .server(-108): return "临时节点不能包含子节点。"
        case .server(-110): return "节点已存在，请使用其他名称。"
        case .server(-111): return "节点包含子节点，请勾选同时删除所有子节点。"
        case .server(-112): return "会话已过期，请重新连接。"
        case .server(let code): return "ZooKeeper 返回错误：\(code)"
        }
    }
}

/// 路径处理集中验证，避免界面与传输层使用不同规则。
enum NodePath {
    /// 校验绝对路径，保留合法的节点名称原文。
    static func validate(_ path: String) throws -> String {
        guard path.first == "/", !path.contains("//"),
              path == "/" || !path.hasSuffix("/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !path.unicodeScalars.contains(where: {
                  let value = $0.value
                  return value == 0 || (1...31).contains(value) || (127...159).contains(value)
                      || (0xD800...0xF8FF).contains(value) || (0xFFF0...0xFFFF).contains(value)
              }) else {
            throw ZooKeeperError.message("请输入合法的绝对路径，例如 /services/api。")
        }
        return path
    }

    /// 将直接子节点名称拼接到父节点路径。
    static func child(_ name: String, of parent: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    /// 返回父节点路径，根节点的父节点仍然为根节点。
    static func parent(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }
}

/// 未实现写入的只读服务明确拒绝节点结构变更。
extension ZooKeeperService {
    /// 为只读服务保留明确的创建失败提示。
    func create(_ path: String, data: Data, ephemeral: Bool) async throws {
        throw ZooKeeperError.message("当前服务不支持新增节点。")
    }
    /// 为只读服务保留明确的删除失败提示。
    func delete(_ path: String, version: Int32) async throws {
        throw ZooKeeperError.message("当前服务不支持删除节点。")
    }
}
