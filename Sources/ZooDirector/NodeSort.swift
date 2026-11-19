import Foundation

/// 节点列表与树中同级节点共用的排序规则。
struct NodeSort: Equatable, Sendable {
    /// 与原生表格列标识一致的排序字段。
    var key: String
    /// 是否按从小到大的顺序排列。
    var ascending: Bool

    /// 时间与数量排序需要完整的节点状态。
    var needsMetadata: Bool { key != "name" }

    /// 固定导航入口置顶、缺失状态置底，同值时以名称和路径稳定排序。
    func precedes(_ left: NodeRow, _ right: NodeRow) -> Bool {
        if (left.navigationTarget != nil) != (right.navigationTarget != nil) {
            return left.navigationTarget != nil
        }
        if needsMetadata {
            let lhs = value(left.stat), rhs = value(right.stat)
            if (lhs == nil) != (rhs == nil) { return lhs != nil }
            if let lhs, let rhs, lhs != rhs { return ascending ? lhs < rhs : lhs > rhs }
        }
        let comparison = left.name.localizedStandardCompare(right.name)
        if comparison != .orderedSame {
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return left.id < right.id
    }

    /// 直接比较原始毫秒时间戳和整数数量，避免按格式化文本排序。
    private func value(_ stat: NodeStat?) -> Int64? {
        guard let stat else { return nil }
        switch key {
        case "created": return stat.created
        case "modified": return stat.modified
        case "children": return Int64(stat.childCount)
        default: return nil
        }
    }
}
