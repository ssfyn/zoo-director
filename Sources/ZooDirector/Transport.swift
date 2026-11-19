import Foundation
import Network

/// 将系统回调和超时竞争收敛为一次恢复。
final class OneShot<Value: Sendable>: @unchecked Sendable {
    /// 保护续体的互斥锁。
    private let lock = NSLock()
    /// 尚未恢复的异步续体。
    private var continuation: CheckedContinuation<Value, any Error>?

    /// 保存仅能恢复一次的续体。
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }

    /// 原子取出续体，在锁外完成恢复。
    @discardableResult
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        let saved = continuation
        continuation = nil
        lock.unlock()
        saved?.resume(with: result)
        return saved != nil
    }
}

/// 系统网络连接的异步封装，所有阻塞等待均发生在后台。
final class ZooKeeperTransport: Sendable {
    /// 系统提供的线程安全连接对象。
    private let connection: NWConnection
    /// 网络回调使用的独立串行队列。
    private let queue = DispatchQueue(label: "app.zoodirector.network", qos: .userInitiated)

    /// 验证单服务器地址并建立尚未启动的 TCP 连接。
    init(endpoint: String) throws {
        let address = try ServerAddress(endpoint: endpoint)
        connection = NWConnection(host: NWEndpoint.Host(address.host),
                                  port: NWEndpoint.Port(rawValue: UInt16(address.port))!, using: .tcp)
    }

    /// 启动连接，默认八秒内未就绪即中止，独立能力查询可指定更短的期限。
    func start(timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OneShot(continuation)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if once.resolve(.failure(ZooKeeperError.message("连接超时，请检查地址和网络。"))) {
                    connection.cancel()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resolve(.success(()))
                case .failed(let error): once.resolve(.failure(error))
                case .cancelled: once.resolve(.failure(ZooKeeperError.message("连接已关闭。")))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// 读取独立版本查询的首段文本，限制长度与等待时间，不用于会话协议读取。
    func serverInfo() async throws -> String {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let once = OneShot<Data>(continuation)
            queue.asyncAfter(deadline: .now() + 2) { [connection] in
                if once.resolve(.failure(ZooKeeperError.message("版本查询超时"))) { connection.cancel() }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, _, error in
                if let error { once.resolve(.failure(error)) }
                else { once.resolve(.success(data ?? Data())) }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 将完整协议帧提交给系统网络栈。
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// 精确读取指定长度，断连和超时都会显式失败。
    private func receive(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OneShot<Data>(continuation)
            queue.asyncAfter(deadline: .now() + 15) { [connection] in
                if once.resolve(.failure(ZooKeeperError.message("等待服务端响应超时，请重新连接。"))) {
                    connection.cancel()
                }
            }
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { once.resolve(.failure(error)) }
                else if let data, data.count == count { once.resolve(.success(data)) }
                else { once.resolve(.failure(ZooKeeperError.message("服务端已关闭连接。"))) }
            }
        }
    }

    /// 按长度前缀读取一帧，限制最大分配为十六兆字节。
    func frame() async throws -> Data {
        var header = JuteReader(data: try await receive(4))
        let length = try header.integer(Int32.self)
        guard length > 0, length <= 16 * 1024 * 1024 else {
            throw ZooKeeperError.message("响应帧长度无效或超过 16 MiB 限制。")
        }
        return try await receive(Int(length))
    }

    /// 取消所有未完成的系统网络操作。
    func cancel() { connection.cancel() }
}
