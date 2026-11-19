import Foundation
@testable import ZooDirector

/// 可离线操作的演示服务，同时提供大目录压力样本。
actor DemoService: ZooKeeperService {
    /// 测试观察关闭操作是否已经回收会话。
    private(set) var closed = false
    /// 用户在演示模式中修改过的数据。
    private var changes: [String: NodeSnapshot] = [:]
    /// 演示写入也通过相同的监听分发器通知界面。
    private let watchHub = WatchHub()
    /// 演示中已删除的路径，不再返回生成的数据。
    private var deleted: Set<String> = []
    /// 固定的示例层次结构。
    private var tree: [String: [String]] = [
        "/": ["applications", "configuration", "services", "stress-test", "zookeeper"],
        "/applications": ["checkout", "gateway", "payments"],
        "/configuration": ["development", "production", "staging"],
        "/services": ["api", "discovery", "workers"],
        "/services/api": ["instance-001", "instance-002", "instance-003"],
        "/configuration/production": ["database", "feature-flags", "rate-limits"]
    ]

    /// 返回单层目录，压力目录包含两万个直接子节点。
    func children(_ path: String) async throws -> [String] {
        try ensureExists(path)
        let original = path == "/stress-test" ? (0..<20_000).map { String(format: "node-%05d", $0) } : []
        return Set(original + tree[path, default: []]).filter { !deleted.contains(NodePath.child($0, of: path)) }.sorted()
    }

    /// 生成可复现的时间和状态供列表展示。
    func stat(_ path: String) async throws -> NodeStat {
        try ensureExists(path)
        if var value = changes[path] { value.stat.childCount = Int32(try await children(path).count); return value.stat }
        let count = try await children(path).count
        return NodeStat(created: 1_730_000_000_000, modified: 1_731_000_000_000,
                        ephemeralOwner: path.hasPrefix("/services/api/instance-") ? 0x0100000000000001 : 0,
                        dataLength: Int32(payload(path).count), childCount: Int32(count))
    }

    /// 返回节点的示例内容和版本。
    func read(_ path: String) async throws -> NodeSnapshot {
        try ensureExists(path)
        if var value = changes[path] { value.stat = try await stat(path); return value }
        return try await NodeSnapshot(data: payload(path), stat: stat(path))
    }

    /// 按版本保存演示内容，不影响任何真实环境。
    func write(_ path: String, data: Data, version: Int32) async throws {
        var value = try await read(path)
        guard value.stat.version == version else { throw ZooKeeperError.server(-103) }
        value.data = data
        value.stat.version += 1
        value.stat.modified = Int64(Date().timeIntervalSince1970 * 1_000)
        value.stat.dataLength = Int32(data.count)
        changes[path] = value
        await watchHub.receive(path: path, change: .data)
    }

    /// 验证真实存在性，避免删除后仍然生成虚构节点。
    private func ensureExists(_ path: String) throws {
        _ = try NodePath.validate(path)
        let parent = NodePath.parent(of: path)
        let name = String(path.split(separator: "/").last ?? "")
        let stress = parent == "/stress-test" && name.hasPrefix("node-") && Int(name.dropFirst(5)).map { (0..<20_000).contains($0) } == true
        guard !deleted.contains(path), path == "/" || tree[parent, default: []].contains(name) || stress else {
            throw ZooKeeperError.server(-101)
        }
    }

    /// 在演示目录中新增节点并发送与真实服务相同的结构通知。
    func create(_ path: String, data: Data, ephemeral: Bool) async throws {
        _ = try NodePath.validate(path)
        guard path != "/", data.count <= 1_000_000 else { throw ZooKeeperError.message("节点路径或内容大小无效。") }
        if (try? ensureExists(path)) != nil { throw ZooKeeperError.server(-110) }
        let parent = NodePath.parent(of: path)
        let parentStat = try await stat(parent)
        guard !parentStat.isEphemeral else { throw ZooKeeperError.server(-108) }
        deleted.remove(path)
        let name = String(path.split(separator: "/").last!)
        if !tree[parent, default: []].contains(name) { tree[parent, default: []].append(name) }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        changes[path] = NodeSnapshot(data: data, stat: NodeStat(created: now, modified: now,
            ephemeralOwner: ephemeral ? 1 : 0, dataLength: Int32(data.count)))
        await watchHub.receive(path: path, change: .created)
        await watchHub.receive(path: parent, change: .children)
    }

    /// 演示删除同样检查版本与空目录，随后通知父目录与检查器。
    func delete(_ path: String, version: Int32) async throws {
        guard path != "/", version >= 0 else { throw ZooKeeperError.message("不能删除根节点或使用未知版本。") }
        let value = try await stat(path)
        guard value.version == version else { throw ZooKeeperError.server(-103) }
        guard value.childCount == 0 else { throw ZooKeeperError.server(-111) }
        deleted.insert(path)
        changes.removeValue(forKey: path)
        tree.removeValue(forKey: path)
        await watchHub.receive(path: path, change: .deleted)
        await watchHub.receive(path: NodePath.parent(of: path), change: .children)
    }

    /// 构造可以直接编辑的 JSON 示例。
    private func payload(_ path: String) -> Data {
        let object: [String: Any] = ["path": path, "environment": "demo", "enabled": true,
                                     "message": "欢迎使用 ZooDirector，双击节点进入，点击 .. 返回上一级。"]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// 演示服务没有需要释放的网络资源。
    func close() async {
        closed = true
        await watchHub.close("测试连接已关闭")
    }

    /// 演示模式使用与真实连接相同的事件消费接口。
    func watchEvents() async -> AsyncStream<WatchEvent> { await watchHub.events() }

    /// 演示监听不需要网络操作，但保留范围合并与移除语义。
    func watch(_ paths: Set<String>, owner: UUID, revision: UInt64) async {
        await watchHub.update(paths: paths, owner: owner, revision: revision) { _, _ in }
    }
}
