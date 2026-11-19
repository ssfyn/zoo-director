import Foundation

/// 由服务端推送的节点变化类型。
enum WatchChange: Int32, Sendable {
    /// 节点被创建。
    case created = 1
    /// 节点被删除。
    case deleted = 2
    /// 节点数据发生变化。
    case data = 3
    /// 直接子节点集合发生变化。
    case children = 4
}

/// 监听流同时传递节点变化、首次同步与连接失效状态。
enum WatchEvent: Sendable {
    /// 当前连接采用的监听方式。
    case mode(String)
    /// 服务端通知某个路径发生变化。
    case changed(String, WatchChange)
    /// 监听已安装；空路径表示事件溢出，需要重新同步所有关注路径。
    case resync(String?)
    /// 监听不可用，基础读写与手动刷新仍可使用。
    case unavailable(String)
    /// 连接失效后不再承诺实时更新。
    case disconnected(String)
}

/// 统一合并多个界面关注者的监听，串行增删服务端监听并分发事件。
actor WatchHub {
    /// 一个关注者的最新请求，代次避免异步旧请求重新安装监听。
    private struct Interest {
        /// 最新请求的单调递增代次。
        var revision: UInt64
        /// 该关注者需要监听的路径。
        var paths: Set<String>
    }
    /// 每个界面上下文的监听范围。
    private var interests: [UUID: Interest] = [:]
    /// 已成功安装到服务端的路径。
    private var installed: Set<String> = []
    /// 本次上下文中注册失败的路径，避免反复请求无权限路径。
    private var rejected: Set<String> = []
    /// 消费事件的多个界面任务。
    private var listeners: [UUID: AsyncStream<WatchEvent>.Continuation] = [:]
    /// 串行执行注册和移除的后台任务。
    private var worker: Task<Void, Never>?
    /// 与具体服务端协议交互的操作。
    private var change: (@Sendable (String, Bool) async throws -> Void)?
    /// 不支持协议时停止后续自动注册。
    private var unsupported = false
    /// 关闭后拒绝新的监听请求。
    private var closed = false
    /// 最近一次不可用原因，供稍后订阅的界面取得状态。
    private var failure: String?
    /// 服务端能力选择完成后的状态说明。
    private var mode = "实时监听中"

    /// 为独立消费者创建有界事件流，终止后自动释放续体。
    func events() -> AsyncStream<WatchEvent> {
        let id = UUID()
        let pair = AsyncStream<WatchEvent>.makeStream(bufferingPolicy: .bufferingNewest(1_024))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        if closed {
            pair.continuation.yield(.disconnected(failure ?? "连接已关闭"))
            pair.continuation.finish()
        } else {
            listeners[id] = pair.continuation
            pair.continuation.yield(.mode(mode))
            if let failure { pair.continuation.yield(.unavailable(failure)) }
        }
        return pair.stream
    }

    /// 先保存实际模式，再通知现有消费者，后来的订阅也能取得相同状态。
    func configureMode(_ status: String) {
        mode = status
        publish(.mode(status))
    }

    /// 普通监听重新安装后同步最终数据，覆盖触发到重新注册之间的变化。
    func resynchronize(_ path: String) {
        if desired.contains(path) { publish(.resync(path)) }
    }

    /// 某个兼容监听重新安装失败时保留原因，不使正常的读取连接失效。
    func reportProblem(_ reason: String) {
        failure = reason
        publish(.unavailable(reason))
    }

    /// 删除已结束的事件消费者。
    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }

    /// 只接受关注者的最新范围，所有注册和移除统一进入一个串行循环。
    func update(paths: Set<String>, owner: UUID, revision: UInt64,
                change: @escaping @Sendable (String, Bool) async throws -> Void) {
        guard !closed, revision > (interests[owner]?.revision ?? 0) else { return }
        interests[owner] = Interest(revision: revision, paths: paths)
        self.change = change
        rejected.formIntersection(desired)
        guard worker == nil else { return }
        worker = Task { await reconcile(); finished() }
    }

    /// 当前所有关注者的路径并集，同一路径只向服务端注册一次。
    private var desired: Set<String> { interests.values.reduce(into: []) { $0.formUnion($1.paths) } }

    /// 工作循环结束后清除句柄，下一次范围变更可以重新启动。
    private func finished() { worker = nil }

    /// 优先移除无用监听，再安装新增监听；注册后主动同步弥补首次读取的时间差。
    private func reconcile() async {
        guard let change else { return }
        while !closed, !Task.isCancelled {
            if let path = installed.subtracting(desired).sorted().first {
                do { try await change(path, false) }
                catch { publish(.unavailable("移除监听失败：\(error.localizedDescription)")) }
                installed.remove(path)
                continue
            }
            guard !unsupported, let path = desired.subtracting(installed).subtracting(rejected).sorted().first else { return }
            do {
                try await change(path, true)
                guard !closed else { return }
                installed.insert(path)
                if desired.contains(path) { publish(.resync(path)) }
            } catch {
                guard !closed else { return }
                rejected.insert(path)
                if case ZooKeeperError.server(-6) = error {
                    unsupported = true
                    failure = "服务端不支持持久 Watch，需要 ZooKeeper 3.6 或以上；请手动刷新。"
                } else { failure = "监听注册失败：\(error.localizedDescription)" }
                publish(.unavailable(failure ?? "监听注册失败"))
            }
        }
    }

    /// 发布受关注路径的变化，移除过程中的迟到事件不会触发界面请求。
    func receive(path: String, change: WatchChange) {
        if desired.contains(path) { publish(.changed(path, change)) }
    }

    /// 向每个消费者广播；发生缓冲溢出时以完整关注范围重同步恢复最终状态。
    private func publish(_ event: WatchEvent) {
        for continuation in listeners.values {
            if case .dropped = continuation.yield(event) { continuation.yield(.resync(nil)) }
        }
    }

    /// 关闭时立即通知界面实时更新已停止，并释放所有订阅与任务。
    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        failure = reason
        worker?.cancel()
        publish(.disconnected(reason))
        for continuation in listeners.values { continuation.finish() }
        listeners.removeAll(); interests.removeAll(); installed.removeAll()
    }
}

extension ZooKeeperService {
    /// 不提供事件源的测试或离线服务默认返回空流。
    func watchEvents() async -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }

    /// 不具备监听能力的服务可继续使用基础浏览功能。
    func watch(_ paths: Set<String>, owner: UUID, revision: UInt64) async {}
}
