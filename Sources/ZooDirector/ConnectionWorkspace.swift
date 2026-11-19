import Foundation
import Observation

/// 窗口级连接管理器，每个连接拥有独立的浏览状态、网络会话和 SSH 隧道。
@MainActor @Observable
final class ConnectionWorkspace {
    /// 统一管理持久化配置和新建、编辑表单，不承载网络会话。
    let configuration: BrowserModel
    /// 已选择过的连接及各自的独立浏览模型。
    private(set) var sessions: [UUID: BrowserModel] = [:]
    /// 所有会话共用的偏好设置，运行状态不写入其中。
    private let defaults: UserDefaults
    /// 测试可替换的连接工厂，每次建立会话都创建独立服务。
    private let serviceFactory: (@Sendable (ConnectionProfile) async throws -> any ZooKeeperService)?
    /// 操作未选中的会话失败时显示的窗口级错误。
    var error: String?

    /// 启动时选中首个已保存配置，仅展示配置页，不创建网络会话。
    init(defaults: UserDefaults = .standard,
         serviceFactory: (@Sendable (ConnectionProfile) async throws -> any ZooKeeperService)? = nil) {
        self.defaults = defaults
        self.serviceFactory = serviceFactory
        configuration = BrowserModel(defaults: defaults)
        if let first = configuration.profiles.first { select(first) }
    }

    /// 当前选中的独立浏览模型，尚未选择时使用空的配置模型。
    var current: BrowserModel {
        guard let id = configuration.selectedConnectionID else { return configuration }
        return sessions[id] ?? configuration
    }

    /// 任意后台会话正在写入时都需要阻止退出。
    var saving: Bool { sessions.values.contains { $0.saving } }
    /// 汇总全部会话的未保存修改，不能只检查前台连接。
    var dirty: Bool { sessions.values.contains { $0.dirty } }

    /// 返回指定连接的模型，不创建或建立会话。
    func session(for profile: ConnectionProfile) -> BrowserModel? { sessions[profile.id] }

    /// 选中连接并恢复它自己的目录、搜索、选择和编辑状态，不影响其他会话。
    func select(_ profile: ConnectionProfile) {
        guard configuration.profiles.contains(where: { $0.id == profile.id }) else { return }
        if sessions[profile.id] == nil {
            let model = BrowserModel(defaults: defaults, serviceFactory: serviceFactory)
            model.profiles = [profile]
            model.selectConnection(profile)
            sessions[profile.id] = model
        }
        configuration.selectConnection(profile)
    }

    /// 仅为目标建立会话，已连接的其他服务继续保持。
    func connect(_ profile: ConnectionProfile) {
        select(profile)
        sessions[profile.id]?.connect(profile)
    }

    /// 仅关闭目标会话，失败时将该会话的保护提示展示到窗口。
    func disconnect(_ profile: ConnectionProfile) {
        guard let model = sessions[profile.id] else { return }
        model.disconnect()
        if let message = model.error { error = message }
    }

    /// 修改配置前保护目标会话，地址变化时只关闭该会话，不影响其他连接。
    @discardableResult
    func update(_ profile: ConnectionProfile, name: String, endpoint: String, ssh: SSHConfiguration?) -> Bool {
        let model = sessions[profile.id]
        guard model?.mayLeave() != false else { error = model?.error; return false }
        guard let original = configuration.profiles.first(where: { $0.id == profile.id }) else { return false }
        if original.endpoint != endpoint || original.ssh != ssh { model?.disconnect() }
        guard configuration.updateConnection(profile, name: name, endpoint: endpoint, ssh: ssh) else { return false }
        if let updated = configuration.profiles.first(where: { $0.id == profile.id }) { model?.profiles = [updated] }
        return true
    }

    /// 删除目标配置及其会话，保留其他连接、收藏与编辑状态。
    func delete(_ profile: ConnectionProfile) {
        let model = sessions[profile.id]
        guard model?.mayLeave() != false else { error = model?.error; return }
        model?.shutdown()
        sessions.removeValue(forKey: profile.id)
        configuration.deleteConnection(profile)
    }

    /// 退出时结束全部会话，包括未显示的连接和正在建立的 SSH 隧道。
    func shutdown() {
        for model in sessions.values { model.shutdown() }
    }
}
