import SwiftUI
import AppKit

/// 单服务器连接配置表单。
struct ConnectionSheet: View {
    /// 用于添加与连接配置的窗口状态。
    @Bindable var model: BrowserModel
    /// 编辑目标，为空时创建新连接。
    let profile: ConnectionProfile?
    /// 内嵌配置页提供显式连接按钮，弹窗仅保存配置。
    let embedded: Bool
    /// 多连接环境中统一处理配置更新和显式连接。
    let workspace: ConnectionWorkspace?
    /// 当前表单独占的临时连接测试。
    @State private var connectionTest = ConnectionTestModel()
    /// 新建配置测试使用稳定标识，避免视图刷新误判为参数变化。
    @State private var draftID = UUID()
    /// 系统关闭表单的操作。
    @Environment(\.dismiss) private var dismiss
    /// 用户输入的配置名称。
    @State private var name = ""
    /// 用户输入的服务器地址。
    @State private var endpoint = "localhost:2181"
    /// 是否通过 SSH 服务器访问 ZooKeeper。
    @State private var useSSH = false
    /// 用户输入的 SSH 连接与认证配置。
    @State private var ssh = SSHConfiguration()
    /// 是否为此连接提交 digest 身份。
    @State private var useDigest = false
    /// 用户名与钥匙串引用，不包含密码。
    @State private var digest = DigestConfiguration(username: "")
    /// 本次输入的密码仅驻留表单内存，不读取已保存密码到界面。
    @State private var password = ""
    /// 区分保留已有密码与用户显式输入新密码（包括空密码）。
    @State private var passwordChanged = false
    /// 表单校验错误。
    @State private var validation: String?

    /// 编辑时预填原配置，新建时名称留空并使用默认地址。
    init(model: BrowserModel, profile: ConnectionProfile? = nil, embedded: Bool = false, workspace: ConnectionWorkspace? = nil) {
        self.model = model
        self.profile = profile
        self.embedded = embedded
        self.workspace = workspace
        _name = State(initialValue: profile?.name ?? "")
        _endpoint = State(initialValue: profile?.endpoint ?? "localhost:2181")
        _useSSH = State(initialValue: profile?.ssh != nil)
        _ssh = State(initialValue: profile?.ssh ?? SSHConfiguration())
        _useDigest = State(initialValue: profile?.digest != nil)
        _digest = State(initialValue: profile?.digest ?? DigestConfiguration(username: ""))
    }

    /// 显示真实连接的范围说明与地址输入。
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(profile == nil ? L10n.text("添加连接") : (embedded ? L10n.text("连接配置") : L10n.text("编辑连接"))).font(.title2).fontWeight(.semibold)
            Form {
                TextField(L10n.text("名称（可选）"), text: $name)
                TextField(useSSH ? L10n.text("ZooKeeper 地址（从 SSH 主机访问）") : L10n.text("服务器"), text: $endpoint)
            }
            Toggle(L10n.text("使用 digest 认证"), isOn: $useDigest)
            if useDigest { digestForm }
            Toggle(L10n.text("使用 SSH 隧道"), isOn: $useSSH)
            if useSSH { sshForm }
            Text(L10n.text("支持单服务器 TCP、digest 认证与版本校验写入。暂不支持 SASL、TLS、集群故障切换与自动重连。"))
                .font(.caption).foregroundStyle(.secondary)
            if let validation { Text(L10n.text(validation)).font(.caption).foregroundStyle(.red) }
            if let message = connectionTest.message {
                Text(L10n.text(message)).font(.caption).foregroundStyle(connectionTest.succeeded ? .green : .red)
                    .textSelection(.enabled)
            }
            HStack {
                if !embedded { Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction) }
                testControls
                Spacer()
                Button(profile == nil ? L10n.text("添加") : L10n.text("保存")) { submit() }
                    .disabled(submissionBlocked)
                if embedded {
                    Button(L10n.text("连接")) { submit(connectAfterSaving: true) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(submissionBlocked)
                }
            }
        }.padding(28).frame(width: 520)
        .onDisappear { connectionTest.cancel() }
        .onChange(of: draft) { _, _ in connectionTest.cancel() }
        .onChange(of: password) { _, _ in connectionTest.cancel() }
    }

    /// 写入期间或当前节点未保存时不能提交配置。
    private var submissionBlocked: Bool {
        let target = profile.flatMap { workspace?.session(for: $0) } ?? model
        return connectionTest.running || target.saving || target.dirty
    }

    /// 草稿保留尚未保存的表单输入，测试不会读取旧的持久化配置。
    private var draft: ConnectionProfile {
        ConnectionProfile(id: profile?.id ?? draftID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                          endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), ssh: useSSH ? ssh : nil,
                          digest: useDigest ? digest : nil)
    }

    /// 校验并返回同一份草稿，保存、连接与测试采用相同的地址规则。
    private func validatedDraft() throws -> ConnectionProfile {
        let profile = draft
        _ = try ServerAddress(endpoint: profile.endpoint)
        try profile.ssh?.validate()
        try profile.digest?.validate()
        return profile
    }

    /// 提供独立测试及取消入口，测试期间显示进度但不改变正式连接状态。
    @ViewBuilder private var testControls: some View {
        if connectionTest.running {
            ProgressView().controlSize(.small)
            Button(L10n.text("取消测试")) { connectionTest.cancel() }
        } else {
            Button(L10n.text("测试连接")) {
                do {
                    let profile = try validatedDraft()
                    validation = nil
                    connectionTest.start(profile, password: passwordOverride)
                } catch { validation = error.localizedDescription }
            }
        }
    }

    /// 有旧引用且未改密码时使用钥匙串，新建和修改密码则传递表单原文。
    private var passwordOverride: String? {
        useDigest && (passwordChanged || profile?.digest == nil) ? password : nil
    }

    /// 认证输入仅提交身份，权限由 ACL 决定，并明确密码的保存位置。
    private var digestForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Form {
                TextField(L10n.text("digest 用户名"), text: $digest.username)
                SecureField(L10n.text(profile?.digest == nil ? "digest 密码" : "digest 密码（未修改时保留已保存密码）"), text: Binding(
                    get: { password }, set: { if password != $0 { password = $0; passwordChanged = true } }
                ))
            }
            Text(L10n.text("密码保存在 macOS 钥匙串。digest 不加密传输，建议配合 SSH 隧道。节点权限由 ACL 决定。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 展示 SSH 地址与公钥认证选项，明确远端目标地址的含义。
    private var sshForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField(L10n.text("SSH 主机"), text: $ssh.host)
                TextField(L10n.text("SSH 端口"), value: $ssh.port, format: .number.grouping(.never))
                TextField(L10n.text("用户名"), text: $ssh.username)
                HStack {
                    TextField(L10n.text("私钥文件（可选）"), text: $ssh.identityFile)
                    Button(L10n.text("选择…")) { chooseIdentity() }
                }
            }
            Text(L10n.text("使用私钥或系统 ssh-agent 认证；留空私钥时尝试默认密钥。不支持密码输入。加密私钥请先加入 ssh-agent。首次连接请先在终端核验并信任 SSH 主机。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("ZooKeeper 地址由 SSH 主机解析和访问，例如 127.0.0.1:2181。"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 选择本机私钥文件，仅保存路径，不读取或复制私钥内容。
    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = L10n.text("选择 SSH 私钥文件")
        if panel.runModal() == .OK, let url = panel.url { ssh.identityFile = url.path }
    }

    /// 先验证地址格式，再持久化连接配置。
    private func submit(connectAfterSaving: Bool = false) {
        do {
            let draft = try validatedDraft()
            let saved: ConnectionProfile?
            if let profile {
                let success: Bool
                if let workspace {
                    success = workspace.update(profile, name: draft.name, endpoint: draft.endpoint, ssh: draft.ssh,
                        digest: draft.digest, password: passwordOverride)
                    saved = workspace.configuration.profiles.first { $0.id == profile.id }
                } else {
                    success = model.updateConnection(profile, name: draft.name, endpoint: draft.endpoint, ssh: draft.ssh,
                        digest: draft.digest, password: passwordOverride)
                    saved = model.profiles.first { $0.id == profile.id }
                }
                guard success else {
                    validation = workspace?.configuration.error ?? model.error
                    return
                }
            } else {
                guard !submissionBlocked else { return }
                saved = model.addConnection(name: draft.name, endpoint: draft.endpoint, ssh: draft.ssh,
                        digest: draft.digest, password: passwordOverride)
                guard let saved else { validation = model.error; return }
                workspace?.select(saved)
            }
            if let saved {
                digest = saved.digest ?? DigestConfiguration(username: "")
                password = ""
                passwordChanged = false
            }
            if connectAfterSaving, let saved {
                if let workspace { workspace.connect(saved) } else { model.connect(saved) }
            }
            if !embedded { dismiss() }
        } catch { validation = error.localizedDescription }
    }
}
