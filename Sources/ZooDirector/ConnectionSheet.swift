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
            Text(profile == nil ? L10n.text("Add Connection") : (embedded ? L10n.text("Connection Settings") : L10n.text("Edit Connection"))).font(.title2).fontWeight(.semibold)
            Form {
                TextField(L10n.text("Name (optional)"), text: $name)
                TextField(useSSH ? L10n.text("ZooKeeper address (from SSH host)") : L10n.text("Server"), text: $endpoint)
            }
            Toggle(L10n.text("Use digest authentication"), isOn: $useDigest)
            if useDigest { digestForm }
            Toggle(L10n.text("Use SSH tunnel"), isOn: $useSSH)
            if useSSH { sshForm }
            Text(L10n.text("Supports single-server TCP, digest authentication and version-checked writes. SASL, TLS, cluster failover and automatic reconnection are not supported yet."))
                .font(.caption).foregroundStyle(.secondary)
            if let validation { Text(L10n.text(validation)).font(.caption).foregroundStyle(.red) }
            if let message = connectionTest.message {
                Text(L10n.text(message)).font(.caption).foregroundStyle(connectionTest.succeeded ? .green : .red)
                    .textSelection(.enabled)
            }
            HStack {
                if !embedded { Button(L10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction) }
                testControls
                Spacer()
                Button(profile == nil ? L10n.text("Add") : L10n.text("Save")) { submit() }
                    .disabled(submissionBlocked)
                if embedded {
                    Button(L10n.text("Connect")) { submit(connectAfterSaving: true) }
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
            Button(L10n.text("Cancel Test")) { connectionTest.cancel() }
        } else {
            Button(L10n.text("Test Connection")) {
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
                TextField(L10n.text("digest username"), text: $digest.username)
                SecureField(L10n.text(profile?.digest == nil ? "digest password" : "digest password (leave unchanged to keep the saved password)"), text: Binding(
                    get: { password }, set: { if password != $0 { password = $0; passwordChanged = true } }
                ))
            }
            Text(L10n.text("Passwords are stored in macOS Keychain. digest does not encrypt traffic; use an SSH tunnel when needed. Node access is determined by ACLs."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 展示 SSH 地址与公钥认证选项，明确远端目标地址的含义。
    private var sshForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField(L10n.text("SSH host"), text: $ssh.host)
                TextField(L10n.text("SSH port"), value: $ssh.port, format: .number.grouping(.never))
                TextField(L10n.text("Username"), text: $ssh.username)
                HStack {
                    Text(ssh.identityFile.isEmpty ? L10n.text("Choose an SSH private key file") : ssh.identityFile)
                        .lineLimit(1).truncationMode(.middle).help(ssh.identityFile)
                    Button(L10n.text("Choose…")) { chooseIdentity() }
                }
            }
            Text(L10n.text("Choose a private key to authorize access. Encrypted keys prompt for a passphrase at connection time. Verify the server fingerprint when asked. ZooDirector keeps its own trusted host records."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("The SSH host resolves and accesses the ZooKeeper address, for example 127.0.0.1:2181."))
                .font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("Forget Trusted Host…")) { forgetTrustedHost() }
                .disabled(connectionTest.running)
        }
    }

    /// 撤销指定服务器的旧身份必须由用户确认，下一次连接重新核对指纹。
    private func forgetTrustedHost() {
        do {
            try ssh.validateServer()
            let alert = NSAlert()
            alert.messageText = L10n.text("Forget this SSH server's saved key?")
            alert.informativeText = "\(ssh.host):\(ssh.port)\n" + L10n.text(
                "Only continue after verifying the key change with your administrator. The next connection will ask you to verify the fingerprint again.")
            alert.addButton(withTitle: L10n.text("Cancel"))
            alert.addButton(withTitle: L10n.text("Forget"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            try SSHKnownHosts.forget(ssh)
            validation = nil
            connectionTest.cancel()
        } catch { validation = error.localizedDescription }
    }

    /// 保存用户选择文件的只读书签，重新选择也可修复旧配置或过期授权。
    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = L10n.text("Choose an SSH private key file")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let bookmark = try SSHPrivateKey.bookmark(for: url)
                _ = try SSHPrivateKey.read(bookmark: bookmark)
                ssh.identityFile = url.path
                ssh.identityBookmark = bookmark
                validation = nil
            } catch { validation = error.localizedDescription }
        }
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
