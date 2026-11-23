import AppKit
import Darwin

/// 以独立的沙箱辅助进程响应 SSH，只经标准输出管道返回确认或口令。
@MainActor
enum SSHAskpass {
    /// 根据主应用传来的语言选择固定文案，不读取其他应用的偏好。
    static func text(_ english: String, _ chinese: String) -> String {
        ProcessInfo.processInfo.environment["ZOODIRECTOR_SSH_LANGUAGE"] == "zh-Hans" ? chinese : english
    }

    /// 展示服务器确认或加密私钥口令窗口，父进程退出后立即结束等待。
    static func run() -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let parent = getppid()
        let started = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                if getppid() != parent || Date().timeIntervalSince(started) > 180 {
                    NSApplication.shared.abortModal()
                }
            }
        }
        // 模态窗口使用独立的循环模式，也必须处理取消和父进程退出。
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        let prompt = CommandLine.arguments.dropFirst().first ?? ""
        let hint = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"]
        let context = ProcessInfo.processInfo.environment["ZOODIRECTOR_SSH_CONTEXT"] ?? ""
        // 主机首次确认使用普通回显提示，部分系统版本不会传入确认类型标记。
        let confirmation = hint == "confirm" || (prompt.hasPrefix("The authenticity of host ")
            && prompt.contains("key fingerprint is:") && prompt.contains("Are you sure"))
        guard !prompt.isEmpty, hint != "none" else { return 1 }
        guard confirmation || prompt.hasPrefix("Enter passphrase for key ") else { return 1 }
        let alert = NSAlert()
        alert.messageText = confirmation
            ? text("Trust this SSH server?", "是否信任此 SSH 服务器？")
            : text("Unlock SSH private key", "解锁 SSH 私钥")
        alert.informativeText = confirmation
            ? text("Verify the fingerprint through a trusted channel before continuing.\n\n", "请通过可信渠道核对指纹后再继续。\n\n") + prompt
            : text("Enter the passphrase for your selected private key. It is not saved.\n\n", "输入所选私钥的加密口令，口令不会保存。\n\n") + context
        alert.addButton(withTitle: confirmation ? text("Trust", "信任") : text("Unlock", "解锁"))
        alert.addButton(withTitle: text("Cancel", "取消"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if !confirmation { alert.accessoryView = field; alert.window.initialFirstResponder = field }
        application.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
        let response = confirmation ? "yes" : field.stringValue
        field.stringValue = ""
        guard !response.contains("\n"), !response.contains("\r"), !response.contains("\0") else { return 1 }
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
        return 0
    }
}

exit(SSHAskpass.run())
