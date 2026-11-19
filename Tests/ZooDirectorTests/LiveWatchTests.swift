import XCTest
@testable import ZooDirector

/// 仅用于隔离实例的协议写入端，扮演独立于 GUI 的外部客户端。
actor ZooKeeperMutationPeer {
    /// 独立 TCP 连接，不共享 GUI 的会话与监听。
    private let transport: ZooKeeperTransport
    /// 递增的请求编号。
    private var xid: Int32 = 1

    /// 验证测试端点并创建独立连接。
    init(_ endpoint: String) throws { transport = try ZooKeeperTransport(endpoint: endpoint) }

    /// 建立独立测试会话。
    func connect() async throws {
        try await transport.start()
        var packet = JuteWriter()
        packet.integer(Int32(0)); packet.integer(Int64(0)); packet.integer(Int32(30_000))
        packet.integer(Int64(0)); packet.buffer(Data(repeating: 0, count: 16)); packet.boolean(false)
        try await transport.send(packet.framed())
        _ = try await transport.frame()
    }

    /// 创建开放权限的持久测试节点，只在测试专属目录内调用。
    func create(_ path: String, text: String = "") async throws {
        var body = JuteWriter()
        body.string(path); body.buffer(Data(text.utf8))
        body.integer(Int32(1)); body.integer(Int32(31)); body.string("world"); body.string("anyone")
        body.integer(Int32(0))
        try await request(1, body)
    }

    /// 模拟其他客户端修改内容。
    func put(_ path: String, text: String) async throws {
        var body = JuteWriter()
        body.string(path); body.buffer(Data(text.utf8)); body.integer(Int32(-1))
        try await request(5, body)
    }

    /// 删除本测试创建的叶节点。
    func delete(_ path: String) async throws {
        var body = JuteWriter()
        body.string(path); body.integer(Int32(-1))
        try await request(2, body)
    }

    /// 串行发送无监听的测试请求并检查真实服务端返回码。
    private func request(_ op: Int32, _ body: JuteWriter) async throws {
        var packet = JuteWriter()
        packet.integer(xid); xid += 1; packet.integer(op); packet.data.append(body.data)
        try await transport.send(packet.framed())
        var reply = JuteReader(data: try await transport.frame())
        _ = try reply.integer(Int32.self); _ = try reply.integer(Int64.self)
        let code = try reply.integer(Int32.self)
        if code != 0 { throw ZooKeeperError.server(code) }
    }

    /// 关闭外部测试会话。
    func close() { transport.cancel() }
}

/// 真实服务端集成测试只使用临时创建的唯一目录。
@MainActor
final class LiveWatchTests: XCTestCase {
    /// 等待真实推送引起的状态变化，避免固定等待代替结果验证。
    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("真实 ZooKeeper 推送未在四秒内更新状态")
    }

    /// 外部客户端创建、修改和删除时，GUI 模型自动更新并保护未保存编辑。
    func testRealServerWatchLifecycle() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ZOODIRECTOR_TEST_ENDPOINT"] else {
            throw XCTSkip("设置隔离的 ZOODIRECTOR_TEST_ENDPOINT 可运行真实 Watch 验证")
        }
        let peer = try ZooKeeperMutationPeer(endpoint)
        try await peer.connect()
        let base = "/zoodirector-watch-" + UUID().uuidString
        let group = base + "/group", node = group + "/node", added = group + "/added"
        let client = try ZooKeeperClient(endpoint: endpoint)
        let log = WatchEventLog()
        try await peer.create(base)
        do {
            try await peer.create(group)
            try await peer.create(node, text: "initial")
            try await client.connect()
            if let expected = ProcessInfo.processInfo.environment["ZOODIRECTOR_EXPECT_WATCH_MODE"] {
                let mode = await client.watchMode
                XCTAssertEqual(mode, expected == "persistent" ? .persistent : .standard)
            }
            let stream = await client.watchEvents()
            let consumer = Task { for await event in stream { await log.append(event) } }
            let model = BrowserModel(serviceFactory: { _ in client })
            model.connect(ConnectionProfile(name: "真实监听隔离测试", endpoint: endpoint))
            try await eventually { !model.loading }
            model.navigate(base)
            try await eventually { !model.loading && model.tree.rows.contains { $0.id == group } }
            model.tree.toggle(group)
            try await eventually { await log.synchronized(group) }
            try await peer.create(added, text: "new")
            try await eventually { model.tree.rows.contains { $0.id == added } }
            model.select(node)
            try await eventually { model.editor == "initial" && !model.reading }
            try await eventually { await log.synchronized(node) }
            try await peer.put(node, text: "remote-one")
            try await eventually { model.editor == "remote-one" }
            try await peer.put(node, text: "remote-two")
            try await eventually { model.editor == "remote-two" }
            model.editor = "local-unsaved"
            try await peer.put(node, text: "remote-three")
            try await eventually { model.inspectorNotice != nil }
            XCTAssertEqual(model.editor, "local-unsaved")
            model.discard()
            try await eventually { model.editor == "remote-three" && !model.reading }
            try await peer.delete(added)
            try await eventually { !model.tree.rows.contains { $0.id == added } }
            model.tree.stop()
            await client.close()
            await consumer.value
            try await peer.delete(node); try await peer.delete(group); try await peer.delete(base)
            await peer.close()
        } catch {
            await client.close()
            try? await peer.delete(added); try? await peer.delete(node); try? await peer.delete(group); try? await peer.delete(base)
            await peer.close()
            throw error
        }
    }
}
