import SwiftUI
import AppKit

/// 工具栏中央的原生空白区域，保留标题栏的窗口操作。
struct TitlebarDragArea: NSViewRepresentable {
    /// 创建直接响应鼠标事件的原生视图，避免空白被 SwiftUI 容器吞掉。
    func makeNSView(context: Context) -> TitlebarDragView { TitlebarDragView() }

    /// 空白区域不持有业务状态，布局变化由系统处理。
    func updateNSView(_ view: TitlebarDragView, context: Context) {}
}

/// 只在工具栏空白范围响应拖动和双击，按钮与输入框不在此视图内。
final class TitlebarDragView: NSView {
    /// 点击非活动窗口的空白时也允许开始拖动或缩放。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 将此视图标记为可以移动窗口的标题栏区域。
    override var mouseDownCanMoveWindow: Bool { true }

    /// 双击执行系统窗口缩放，其他左键按下沿用原生窗口拖动。
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            window.performZoom(nil)
        } else {
            window.performDrag(with: event)
        }
    }
}
