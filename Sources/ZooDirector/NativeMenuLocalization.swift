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
        "orderFrontStandardAboutPanel:": "关于 ZooDirector",
        "hide:": "隐藏 ZooDirector", "hideOtherApplications:": "隐藏其他应用",
        "unhideAllApplications:": "显示全部", "terminate:": "退出 ZooDirector",
        "performClose:": "关闭窗口", "performMiniaturize:": "最小化",
        "performZoom:": "缩放", "toggleFullScreen:": "进入全屏幕",
        "arrangeInFront:": "前置全部窗口", "undo:": "撤销", "redo:": "重做",
        "cut:": "剪切", "copy:": "复制", "paste:": "粘贴", "selectAll:": "全选",
        "pasteAsPlainText:": "粘贴并匹配样式", "showHelp:": "ZooDirector 帮助"
    ]
    /// 没有动作的菜单容器以系统英文或中文标题识别。
    private static let containerTitles = [
        "File": "文件", "文件": "文件", "Edit": "编辑", "编辑": "编辑",
        "View": "显示", "显示": "显示", "Window": "窗口", "窗口": "窗口",
        "Help": "帮助", "帮助": "帮助", "Services": "服务", "服务": "服务"
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
