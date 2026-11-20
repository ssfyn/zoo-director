import AppKit

/// 将 AppKit 自动生成的菜单标题与应用语言同步，保留系统动作和快捷键。
@MainActor
enum NativeMenuLocalization {
    /// 观察系统动态重建菜单的通知，避免菜单打开时恢复为系统语言。
    private static var observers: [any NSObjectProtocol] = []
    /// 忽略修改标题引发的嵌套通知。
    private static var refreshing = false
    /// 系统菜单通过稳定的动作选择器识别，避免依赖用户的系统显示语言。
    private static let actionTitles = [
        "orderFrontStandardAboutPanel:": "About ZooDirector",
        "hide:": "Hide ZooDirector", "hideOtherApplications:": "Hide Others",
        "unhideAllApplications:": "Show All", "terminate:": "Quit ZooDirector",
        "performClose:": "Close Window", "performMiniaturize:": "Minimize",
        "performZoom:": "Zoom", "toggleFullScreen:": "Enter Full Screen",
        "arrangeInFront:": "Bring All to Front", "undo:": "Undo", "redo:": "Redo",
        "cut:": "Cut", "copy:": "Copy", "paste:": "Paste", "selectAll:": "Select All",
        "pasteAsPlainText:": "Paste and Match Style", "showHelp:": "ZooDirector Help"
    ]
    /// 没有动作的菜单容器以系统英文或中文标题识别。
    private static let containerTitles = [
        "File": "File", "文件": "File", "Edit": "Edit", "编辑": "Edit",
        "View": "View", "显示": "View", "Window": "Window", "窗口": "Window",
        "Help": "Help", "帮助": "Help", "Services": "Services", "服务": "Services"
    ]

    /// 安装一次菜单监听，让系统菜单和应用内显式选择保持一致。
    static func startObserving() {
        guard observers.isEmpty else { return }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didChangeItemNotification, NSMenu.didAddItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refresh() }
            })
        }
        refresh()
    }

    /// 刷新现有原生菜单；递归仅修改已知系统标签，不改变业务菜单项的行为。
    static func refresh(_ menu: NSMenu? = NSApp.mainMenu) {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        translate(menu)
    }

    /// 递归更新标题及子菜单容器，只写入确实变化的文本以避免通知循环。
    private static func translate(_ menu: NSMenu?) {
        guard let menu else { return }
        if let key = containerTitles[menu.title] {
            let title = L10n.text(key)
            if menu.title != title { menu.title = title }
        }
        for item in menu.items {
            if let action = item.action, let key = actionTitles[NSStringFromSelector(action)] {
                let title = L10n.text(key)
                if item.title != title { item.title = title }
            } else if let key = containerTitles[item.title], item.title != L10n.text(key) {
                item.title = L10n.text(key)
            }
            if let submenu = item.submenu { translate(submenu) }
        }
    }
}
