import Foundation

/// 基于原生 TCP 的基础 ZooKeeper 客户端，隔离请求状态与界面线程。
actor ZooKeeperClient: ZooKeeperService {
    /// 负责二进制帧传输的网络对象。
    private let transport: ZooKeeperTransport
    /// 已完成 digest 身份注册时，新节点默认限定为该身份可访问。
    private var authenticatedDigest = false
    /// 实际 TCP 地址，SSH 模式下为本机转发地址。
    private let endpoint: String
    /// 当前会话独占的 SSH 隧道，直连时为空。
    private let tunnel: SSHTunnel?
    /// 正在等待服务端响应的请求。
    private var pending: [Int32: CheckedContinuation<Data, any Error>] = [:]
    /// 下一个普通请求编号。
    private var nextXID: Int32 = 1
    /// 接收循环任务。
    private var readerTask: Task<Void, Never>?
    /// 会话心跳任务。
    private var heartbeatTask: Task<Void, Never>?
    /// 连接关闭后拒绝所有新请求。
    private var closed = false
    /// 合并多个界面上下文的监听与事件消费者。
    private let watchHub = WatchHub()
    /// 能力明确前默认使用兼容协议，不能向旧服务端发送未知操作码。
    private(set) var watchMode = ZooKeeperWatchMode.standard
    /// 兼容模式下仍然需要持续重新注册的路径。
    private var legacyDesired: Set<String> = []
    /// 服务端尚未触发的数据监听，取消范围后等待其自然失效。
    private var legacyDataArmed: Set<String> = []
    /// 服务端尚未触发的子节点监听。
    private var legacyChildrenArmed: Set<String> = []
    /// 当前只安装了存在性监听的缺失节点。
    private var legacyMissing: Set<String> = []
    /// 合并同一路径多条兼容通知，串行恢复单次监听。
    private var legacyPending: Set<String> = []
    /// 兼容监听的唯一重新注册任务。
    private var legacyTask: Task<Void, Never>?

    /// 创建独立连接对象。
    init(endpoint: String, tunnel: SSHTunnel? = nil) throws {
        self.endpoint = endpoint
        transport = try ZooKeeperTransport(endpoint: endpoint)
        self.tunnel = tunnel
    }

    /// 按配置建立可选的 SSH 隧道与会话，失败或取消时回收全部资源。
    static func open(profile: ConnectionProfile, password: String? = nil,
                     passwordStore: any DigestPasswordStore = KeychainDigestPasswordStore()) async throws -> ZooKeeperClient {
        var tunnel: SSHTunnel?
        do {
            let credential = try digestPassword(profile: profile, override: password, store: passwordStore)
            var endpoint = profile.endpoint
            if let configuration = profile.ssh {
                let forwarding = try await SSHTunnel()
                tunnel = forwarding
                endpoint = try await forwarding.start(configuration: configuration, endpoint: endpoint)
            }
            try Task.checkCancellation()
            let client = try ZooKeeperClient(endpoint: endpoint, tunnel: tunnel)
            do {
                try await client.connect(digest: profile.digest, password: credential)
                try Task.checkCancellation()
                return client
            } catch {
                await client.close()
                throw error
            }
        } catch {
            await tunnel?.stop()
            throw error
        }
    }

    /// 完成会话握手，随后启动接收与心跳循环。
    func connect(digest: DigestConfiguration? = nil, password: String? = nil) async throws {
        do {
            try await transport.start()
            var packet = JuteWriter()
            packet.integer(Int32(0))
            packet.integer(Int64(0))
            packet.integer(Int32(30_000))
            packet.integer(Int64(0))
            packet.buffer(Data(repeating: 0, count: 16))
            packet.boolean(false)
            try await transport.send(packet.framed())
            var reply = JuteReader(data: try await transport.frame())
            _ = try reply.integer(Int32.self)
            let timeout = try reply.integer(Int32.self)
            let session = try reply.integer(Int64.self)
            _ = try reply.buffer()
            guard timeout > 0, session != 0 else { throw ZooKeeperError.server(-112) }
            if let digest {
                try digest.validate()
                guard let password else { throw ZooKeeperError.message("未找到 digest 密码，请编辑连接后重新输入。") }
                try await authenticateDigest(username: digest.username, password: password)
                authenticatedDigest = true
            }
            try Task.checkCancellation()
            readerTask = Task { [weak self] in await self?.receiveLoop() }
            heartbeatTask = Task { [weak self] in
                await self?.heartbeat(every: min(5, max(0.2, Double(timeout) / 3_000)))
            }
            watchMode = await ZooKeeperWatchMode.detect(endpoint: endpoint)
            await watchHub.configureMode(watchMode.status)
        } catch {
            fail(error)
            throw error
        }
    }

    /// 在创建网络连接前读取密码，草稿测试可临时覆盖但不保存。
    private static func digestPassword(profile: ConnectionProfile, override: String?, store: any DigestPasswordStore) throws -> String? {
        guard let digest = profile.digest else { return nil }
        try digest.validate()
        if let override { return override }
        guard let saved = try store.load(digest.credentialID) else {
            throw ZooKeeperError.message("未找到 digest 密码，请编辑连接后重新输入。")
        }
        return saved
    }

    /// 握手后独占读取认证响应；认证完成前不启动普通请求、心跳或监听。
    private func authenticateDigest(username: String, password: String) async throws {
        let auth = Data("\(username):\(password)".utf8)
        guard auth.count <= 1_000_000 else { throw ZooKeeperError.message("digest 认证信息过长。") }
        var packet = JuteWriter()
        packet.integer(Int32(-4)); packet.integer(Int32(100))
        packet.integer(Int32(0)); packet.string("digest"); packet.buffer(auth)
        try await transport.send(packet.framed())
        var reply = JuteReader(data: try await transport.frame())
        let xid = try reply.integer(Int32.self)
        _ = try reply.integer(Int64.self)
        let code = try reply.integer(Int32.self)
        guard xid == -4 else { throw ZooKeeperError.message("digest 认证响应无效，连接已关闭。") }
        guard code == 0 else { throw ZooKeeperError.server(code) }
    }

    /// 读取当前层的节点名，不逐个请求子节点元信息。
    func children(_ path: String) async throws -> [String] {
        var body = JuteWriter()
        body.string(try NodePath.validate(path))
        body.boolean(false)
        var reply = JuteReader(data: try await request(op: 8, body: body))
        let count = try reply.integer(Int32.self)
        guard count >= 0, count <= (reply.data.count - reply.offset) / 4 else {
            throw ZooKeeperError.message("服务端返回了无效的子节点数量。")
        }
        var names: [String] = []
        names.reserveCapacity(Int(count))
        for _ in 0..<count { names.append(try reply.string()) }
        return names.sorted()
    }

    /// 获取列表需要的时间和子节点数，避免下载每个节点的数据。
    func stat(_ path: String) async throws -> NodeStat {
        var body = JuteWriter()
        body.string(try NodePath.validate(path))
        body.boolean(false)
        var reply = JuteReader(data: try await request(op: 3, body: body))
        return try reply.stat()
    }

    /// 同时取得节点字节和状态，保持数据与版本的一致性。
    func read(_ path: String) async throws -> NodeSnapshot {
        var body = JuteWriter()
        body.string(try NodePath.validate(path))
        body.boolean(false)
        var reply = JuteReader(data: try await request(op: 4, body: body))
        return try NodeSnapshot(data: reply.buffer(), stat: reply.stat())
    }

    /// 使用数据版本执行更新，网络失败时不自动重试写入。
    func write(_ path: String, data: Data, version: Int32) async throws {
        guard data.count <= 1_000_000 else { throw ZooKeeperError.message("首版限制写入不超过 1,000,000 字节。") }
        var body = JuteWriter()
        body.string(try NodePath.validate(path))
        body.buffer(data)
        body.integer(version)
        _ = try await request(op: 5, body: body)
    }

    /// 使用标准创建协议写入初始内容，失败时不重试以避免重复创建。
    func create(_ path: String, data: Data, ephemeral: Bool) async throws {
        let path = try NodePath.validate(path)
        guard path != "/", data.count <= 1_000_000 else {
            throw ZooKeeperError.message("不能创建根节点，节点内容不能超过 1,000,000 字节。")
        }
        var body = JuteWriter()
        body.string(path); body.buffer(data)
        body.integer(Int32(1)); body.integer(Int32(31))
        body.string(authenticatedDigest ? "auth" : "world"); body.string(authenticatedDigest ? "" : "anyone")
        body.integer(Int32(ephemeral ? 1 : 0))
        _ = try await request(op: 1, body: body)
    }

    /// 删除单个叶节点并检查版本，服务端负责拒绝非空目录。
    func delete(_ path: String, version: Int32) async throws {
        let path = try NodePath.validate(path)
        guard path != "/", version >= 0 else { throw ZooKeeperError.message("不能删除根节点或使用未知版本。") }
        var body = JuteWriter()
        body.string(path); body.integer(version)
        _ = try await request(op: 2, body: body)
    }

    /// 注册请求后再发送，保证快速响应不会丢失。
    private func request(op: Int32, body: JuteWriter) async throws -> Data {
        guard !closed else { throw ZooKeeperError.message("连接已断开，请重新连接。") }
        guard pending.count < 32 else { throw ZooKeeperError.message("请求过多，请稍后再试。") }
        let xid = nextXID
        nextXID = nextXID == Int32.max ? 1 : nextXID + 1
        var packet = JuteWriter()
        packet.integer(xid)
        packet.integer(op)
        packet.data.append(body.data)
        let frame = packet.framed()
        return try await withCheckedThrowingContinuation { continuation in
            pending[xid] = continuation
            Task { [weak self, transport] in
                do { try await transport.send(frame) }
                catch { await self?.fail(error) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.expire(xid)
            }
        }
    }

    /// 单个请求超时即废弃会话，避免继续使用状态不明确的连接。
    private func expire(_ xid: Int32) {
        guard pending[xid] != nil else { return }
        fail(ZooKeeperError.message("请求超时。若刚才正在保存，请重新连接并读取数据以确认写入结果。"))
    }

    /// 分发普通请求响应、服务端监听通知与会话事件。
    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                var reply = JuteReader(data: try await transport.frame())
                let xid = try reply.integer(Int32.self)
                _ = try reply.integer(Int64.self)
                let code = try reply.integer(Int32.self)
                if xid == -1 { try await receiveWatch(&reply); continue }
                guard xid >= 0 else { continue }
                guard let continuation = pending.removeValue(forKey: xid) else { continue }
                if code == 0 { continuation.resume(returning: reply.data.subdata(in: reply.offset..<reply.data.count)) }
                else { continuation.resume(throwing: ZooKeeperError.server(code)) }
            }
        } catch { fail(error) }
    }

    /// 解码服务端通知，只有正常读写会话才继续声明监听有效。
    private func receiveWatch(_ reader: inout JuteReader) async throws {
        let type = try reader.integer(Int32.self)
        let state = try reader.integer(Int32.self)
        let path = try reader.string()
        if type == -1 {
            if state != 3 { fail(ZooKeeperError.message("会话状态发生变化（\(state)），请重新连接以恢复实时更新。")) }
        } else if let change = WatchChange(rawValue: type) {
            if watchMode == .standard { consumeLegacyNotification(path, change: change) }
            await watchHub.receive(path: path, change: change)
        }
    }

    /// 为界面创建独立的变化订阅，不占用普通请求响应编号。
    func watchEvents() async -> AsyncStream<WatchEvent> { await watchHub.events() }

    /// 将关注范围交给串行管理器，多个界面使用同一路径时不会重复安装。
    func watch(_ paths: Set<String>, owner: UUID, revision: UInt64) async {
        await watchHub.update(paths: paths, owner: owner, revision: revision) { [weak self] path, enabled in
            guard let self else { throw ZooKeeperError.message("连接已释放。") }
            try await self.changeWatch(path, enabled: enabled)
        }
    }

    /// 按已确认的能力安装监听，旧服务端取消后停止重注册，不发送不支持的移除指令。
    private func changeWatch(_ path: String, enabled: Bool) async throws {
        if watchMode == .standard {
            if enabled {
                legacyDesired.insert(path)
                do { try await installLegacyWatches(path) }
                catch { legacyDesired.remove(path); throw error }
            } else { legacyDesired.remove(path); legacyPending.remove(path) }
            return
        }
        var body = JuteWriter()
        body.string(try NodePath.validate(path))
        body.integer(Int32(enabled ? 0 : 3))
        do { _ = try await request(op: enabled ? 106 : 18, body: body) }
        catch ZooKeeperError.server(-121) { if enabled { throw ZooKeeperError.server(-121) } }
    }

    /// 按服务端协商的超时定期发送会话心跳。
    private func heartbeat(every interval: Double) async {
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(interval))
                try Task.checkCancellation()
                var packet = JuteWriter()
                packet.integer(Int32(-2))
                packet.integer(Int32(11))
                try await transport.send(packet.framed())
            }
        } catch { if !Task.isCancelled { fail(error) } }
    }

    /// 统一结束所有等待中的请求并释放网络资源。
    private func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true
        Task { await watchHub.close(error.localizedDescription) }
        transport.cancel()
        if let tunnel { Task { await tunnel.stop() } }
        readerTask?.cancel()
        heartbeatTask?.cancel()
        legacyTask?.cancel()
        legacyDesired.removeAll(); legacyPending.removeAll()
        legacyDataArmed.removeAll(); legacyChildrenArmed.removeAll(); legacyMissing.removeAll()
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
    }

    /// 关闭会话传输；界面不创建临时节点，不依赖立即结束服务端会话。
    func close() async {
        fail(ZooKeeperError.message("连接已关闭。"))
        await tunnel?.stop()
    }
}

extension ZooKeeperClient {
    /// 以普通存在性与子节点监听兼容旧版服务端；缺失节点只保留创建监听。
    private func installLegacyWatches(_ path: String) async throws {
        guard legacyDesired.contains(path), !closed else { return }
        if !legacyDataArmed.contains(path) {
            legacyDataArmed.insert(path)
            var exists = JuteWriter()
            exists.string(try NodePath.validate(path)); exists.boolean(true)
            do {
                _ = try await request(op: 3, body: exists)
                legacyMissing.remove(path)
            } catch ZooKeeperError.server(-101) {
                // exists 在节点不存在时仍成功安装存在性监听，等待重新创建。
                legacyMissing.insert(path)
                return
            } catch {
                legacyDataArmed.remove(path)
                throw error
            }
        }
        guard legacyDesired.contains(path), !legacyMissing.contains(path), !legacyChildrenArmed.contains(path) else { return }
        legacyChildrenArmed.insert(path)
        var children = JuteWriter()
        children.string(path); children.boolean(true)
        do { _ = try await request(op: 8, body: children) }
        catch ZooKeeperError.server(-101) { legacyChildrenArmed.remove(path) }
        catch { legacyChildrenArmed.remove(path); throw error }
    }

    /// 单次监听触发后先更新安装状态；已取消的路径不再重新注册。
    private func consumeLegacyNotification(_ path: String, change: WatchChange) {
        switch change {
        case .created:
            legacyDataArmed.remove(path); legacyMissing.remove(path)
        case .deleted:
            legacyDataArmed.remove(path); legacyChildrenArmed.remove(path); legacyMissing.insert(path)
        case .data: legacyDataArmed.remove(path)
        case .children: legacyChildrenArmed.remove(path)
        }
        guard legacyDesired.contains(path), !closed else {
            if !legacyDataArmed.contains(path), !legacyChildrenArmed.contains(path) { legacyMissing.remove(path) }
            return
        }
        legacyPending.insert(path)
        guard legacyTask == nil else { return }
        legacyTask = Task { [weak self] in await self?.restoreLegacyWatches() }
    }

    /// 合并短时间内的变化，重新安装后再次同步，确保界面最终读取到最新状态。
    private func restoreLegacyWatches() async {
        while !closed, !Task.isCancelled, !legacyPending.isEmpty {
            do { try await Task.sleep(for: .milliseconds(30)); try Task.checkCancellation() }
            catch { break }
            let paths = Array(legacyPending.sorted().prefix(8))
            legacyPending.subtract(paths)
            for path in paths where legacyDesired.contains(path) {
                do {
                    try await installLegacyWatches(path)
                    await watchHub.resynchronize(path)
                } catch {
                    if !closed { await watchHub.reportProblem("兼容监听重新注册失败：\(error.localizedDescription)") }
                }
            }
        }
        legacyTask = nil
    }
}
