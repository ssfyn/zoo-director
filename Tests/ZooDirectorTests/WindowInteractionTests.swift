import AppKit
import XCTest
@testable import ZooDirector

/// 记录窗口操作，验证事件分发时无需真的拖动或显示窗口。
@MainActor
private final class RecordingWindow: NSWindow {
    /// 接收到的窗口缩放次数。
    var zoomCount = 0
    /// 接收到的原生拖动次数。
    var dragCount = 0

    /// 记录缩放请求，避免测试改变实际窗口布局。
    override func performZoom(_ sender: Any?) { zoomCount += 1 }

    /// 记录拖动请求，避免测试等待真实鼠标释放。
    override func performDrag(with event: NSEvent) { dragCount += 1 }
}

/// 回归工具栏空白处的双击缩放与拖动行为。
@MainActor
final class WindowInteractionTests: XCTestCase {
    /// 单击交给原生拖动，连续双击各触发一次窗口缩放。
    func testBlankTitlebarDispatchesWindowActions() throws {
        let window = RecordingWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        let view = TitlebarDragView()
        window.contentView = view
        let single = try event(clickCount: 1)
        view.mouseDown(with: single)
        XCTAssertEqual(window.dragCount, 1)
        XCTAssertEqual(window.zoomCount, 0)
        let double = try event(clickCount: 2)
        view.mouseDown(with: double)
        view.mouseDown(with: double)
        XCTAssertEqual(window.zoomCount, 2)
        XCTAssertEqual(window.dragCount, 1)
        XCTAssertTrue(view.mouseDownCanMoveWindow)
        XCTAssertTrue(view.acceptsFirstMouse(for: single))
        window.contentView = nil
    }

    /// 创建不依赖真实鼠标位置的左键按下事件。
    private func event(clickCount: Int) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                        clickCount: clickCount, pressure: 1))
    }
}
