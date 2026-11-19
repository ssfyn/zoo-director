import Foundation
import Observation

/// 使用独立临时会话测试当前表单参数，不保存配置或占用正式连接。
@MainActor @Observable
final class ConnectionTestModel {
    /// 是否正在等待 TCP 或 SSH 握手。
    private(set) var running = false
    /// 最近一次测试的用户可见结果。
    private(set) var message: String?
    /// 最近一次测试是否成功。
    private(set) var succeeded = false
    /// 测试任务，可在关闭表单或主动取消时中止。
    private var task: Task<Void, Never>?
    /// 阻止被取消的测试覆盖新表单或新测试的结果。
    private var generation = UUID()
    /// 可替换工厂，正式环境执行完整 ZooKeeper 会话握手。
    private let factory: (@Sendable (ConnectionProfile) async throws -> any ZooKeeperService)?

    /// 默认使用独立的 ZooKeeper 客户端，测试时可注入受控握手。
    init(factory: (@Sendable (ConnectionProfile) async throws -> any ZooKeeperService)? = nil) { self.factory = factory }

    /// 测试当前输入的参数，成功、失败或取消都不留下临时会话。
    func start(_ profile: ConnectionProfile, password: String? = nil) {
        cancel()
        let token = generation
        running = true
        task = Task {
            do {
                try Task.checkCancellation()
                let service: any ZooKeeperService
                if let factory { service = try await factory(profile) }
                else { service = try await ZooKeeperClient.open(profile: profile, password: password) }
                await service.close()
                guard token == generation, !Task.isCancelled else { return }
                running = false; succeeded = true
                message = profile.digest == nil ? "连接成功，已完成 ZooKeeper 会话握手。"
                    : "连接成功，已提交 digest 身份；节点权限由对应 ACL 决定。"
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                running = false; succeeded = false
                message = "连接失败：\(error.localizedDescription)"
            }
        }
    }

    /// 取消或清除旧结果，迟到返回的临时服务仍由原任务关闭。
    func cancel() {
        task?.cancel(); task = nil
        generation = UUID()
        running = false; message = nil; succeeded = false
    }
}
