import Foundation

/// 搜索范围始终以当前打开的目录为起点。
enum SearchScope: String, CaseIterable, Identifiable {
    case current = "Current directory"
    case descendants = "Include subdirectories"
    /// 范围选择器使用的稳定标识。
    var id: String { rawValue }
}

/// 有限递归搜索的结果及不完整性信息。
struct NodeSearchResult: Sendable {
    /// 匹配的节点完整路径。
    var paths: [String]
    /// 已扫描的目录数量。
    var scanned: Int
    /// 无权读取或已被删除的目录数量。
    var skipped: Int
    /// 是否因达到资源上限而停止。
    var limited: Bool
}

/// 按层遍历指定目录下的名称，不下载节点数据。
enum NodeSearch {
    /// 在限定的目录数、节点数和深度内搜索，最多并发四个目录请求。
    static func run(
        root: String, query: String, service: any ZooKeeperService,
        directoryLimit: Int = 2_000, nodeLimit: Int = 100_000, resultLimit: Int = 2_000,
        progress: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> NodeSearchResult {
        var frontier = [root]
        var result = NodeSearchResult(paths: [], scanned: 0, skipped: 0, limited: false)
        var examined = 0
        for _ in 0..<64 {
            var next: [String] = []
            for start in stride(from: 0, to: frontier.count, by: 4) {
                try Task.checkCancellation()
                let remaining = directoryLimit - result.scanned
                guard remaining > 0 else { result.limited = true; return result }
                let end = min(start + min(4, remaining), frontier.count)
                let batch = Array(frontier[start..<end])
                let children = await fetch(batch, service: service)
                try Task.checkCancellation()
                result.scanned += batch.count
                for (parent, names) in children {
                    guard let names else { result.skipped += 1; continue }
                    for name in names {
                        examined += 1
                        if examined > nodeLimit { result.limited = true; return result }
                        let path = NodePath.child(name, of: parent)
                        if name.localizedCaseInsensitiveContains(query) { result.paths.append(path) }
                        if result.paths.count >= resultLimit { result.limited = true; return result }
                        // 只有请求过子节点才能判断叶节点，所有候选路径都受目录预算约束。
                        if next.count < directoryLimit { next.append(path) }
                        else { result.limited = true }
                    }
                }
                await progress(result.scanned)
            }
            if next.isEmpty { result.paths.sort(); return result }
            frontier = next
        }
        result.limited = true
        result.paths.sort()
        return result
    }

    /// 收集单批目录，个别目录失败时保留其他结果。
    private static func fetch(_ paths: [String], service: any ZooKeeperService) async -> [(String, [String]?)] {
        await withTaskGroup(of: (String, [String]?).self) { group in
            for path in paths {
                group.addTask { (path, try? await service.children(path)) }
            }
            var values: [(String, [String]?)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }
    }
}
