import SwiftUI

/// ZooDirector 的原生 macOS 应用入口。
@main
struct ZooDirectorApp: App {
    /// 退出时保护未保存内容的应用代理。
    @NSApplicationDelegateAdaptor(ZooDirectorAppDelegate.self) private var delegate
    /// 各连接独立运行的窗口级状态。
    @State private var workspace = ConnectionWorkspace()
    /// 跨窗口与菜单共享的可观察语言选择。
    @State private var language = LanguagePreferences.shared
    /// 首选项以弹窗展示，避免更改语言时重建业务窗口。
    @State private var showingPreferences = false
    /// 菜单始终作用于当前选中的连接。
    private var model: BrowserModel { workspace.current }

    /// 组装窗口、菜单与快捷键。
    var body: some Scene {
        Window("ZooDirector", id: "browser") {
            BrowserView(model: model, workspace: workspace)
                .environment(\.locale, language.locale)
                .frame(minWidth: 1080, minHeight: 640)
                .sheet(isPresented: $showingPreferences) {
                    PreferencesView(preferences: language)
                }
                .onChange(of: language.selection) {
                    Task { @MainActor in
                        await Task.yield()
                        NativeMenuLocalization.refresh()
                    }
                }
                .onAppear {
                    delegate.workspace = workspace
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("About ZooDirector")) { AppBuildInfo.showAboutPanel() }
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("Preferences…")) { showingPreferences = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button(L10n.text("New Connection…")) { workspace.configuration.beginAddingConnection() }.keyboardShortcut("n")
                Button(L10n.text("Go to Folder…")) { NotificationCenter.default.post(name: .focusPath, object: nil) }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!model.showingBrowser)
            }
            CommandMenu(L10n.text("Browse")) {
                Button(L10n.text("Back")) { model.moveHistory(-1) }.keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.showingBrowser || !model.canBack)
                Button(L10n.text("Forward")) { model.moveHistory(1) }.keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.showingBrowser || !model.canForward)
                Button(L10n.text("Up One Level")) { model.navigate(NodePath.parent(of: model.path)) }
                    .keyboardShortcut(.upArrow, modifiers: .command).disabled(!model.showingBrowser || model.path == "/")
                Button(L10n.text("Refresh")) { model.refresh() }.keyboardShortcut("r").disabled(!model.showingBrowser)
                Divider()
                Button(L10n.text("Save Data")) { NotificationCenter.default.post(name: .confirmSave, object: nil) }.keyboardShortcut("s").disabled(!model.dirty || model.saving || !model.connectionEstablished)
            }
        }
    }
}

extension Notification.Name {
    /// 菜单通知界面确认保存数据。
    static let confirmSave = Notification.Name("app.zoodirector.confirmSave")
    /// 菜单通知路径输入框获取焦点。
    static let focusPath = Notification.Name("app.zoodirector.focusPath")
}

/// 管理原生应用退出行为，避免丢失未保存的节点修改。
@MainActor
final class ZooDirectorAppDelegate: NSObject, NSApplicationDelegate {
    /// 当前窗口的数据模型。
    var workspace: ConnectionWorkspace?

    /// 应用启动后注册普通桌面应用行为。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 显式设置程序坞图标，避免本地重建后仍显示系统缓存的默认图标。
        if let iconURL = Bundle.main.url(forResource: "ZooDirector", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NativeMenuLocalization.startObserving()
        Task { @MainActor in
            await Task.yield()
            NativeMenuLocalization.refresh()
        }
    }

    /// 应用结束前关闭所有独占的 SSH 隧道。
    func applicationWillTerminate(_ notification: Notification) {
        workspace?.shutdown()
        SSHTunnel.stopAll()
    }

    /// 写入中拒绝退出；未保存时提供明确的放弃确认。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspace?.saving == true { return .terminateCancel }
        guard workspace?.dirty == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L10n.text("Connections Have Unsaved Changes")
        alert.informativeText = L10n.text("Quitting will close all connections and discard unsaved edits in every connection's editor.")
        alert.addButton(withTitle: L10n.text("Continue Editing"))
        alert.addButton(withTitle: L10n.text("Discard and Quit"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
