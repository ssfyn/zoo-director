import Foundation

/// 结构写入的路径校验与批量删除，所有请求均禁止自动重试。
enum NodeMutations {
    /// 将单个合法名称拼接到明确的父路径，不允许名称暗含额外层级。
    static func creationPath(parent: String, name: String) throws -> String {
        _ = try NodePath.validate(parent)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw ZooKeeperError.message("请输入单个节点名称，名称不能包含 /，也不能是 . 或 ..。")
        }
        return try NodePath.validate(NodePath.child(name, of: parent))
    }

    /// 合并重复及父子重叠目标，防止同一个节点被批量删除两次。
    static func deletionRoots(_ paths: Set<String>) throws -> [String] {
        var roots: [String] = []
        for path in paths.sorted() {
            _ = try NodePath.validate(path)
            guard path != "/" else { throw ZooKeeperError.message("根节点不能删除。") }
            if !roots.contains(where: { path.hasPrefix($0 + "/") }) { roots.append(path) }
        }
        return roots
    }

    /// 删除前读取全部目标的版本；非递归时发现非空目录就拒绝整批操作。
    static func deletionPlan(paths: [String], recursive: Bool, service: any ZooKeeperService) async throws -> [(String, Int32)] {
        var pending = try deletionRoots(Set(paths))
        var plan: [(String, Int32)] = []
        while let path = pending.popLast() {
            try Task.checkCancellation()
            let value = try await service.stat(path)
            let children = try await service.children(path)
            guard recursive || children.isEmpty else {
                throw ZooKeeperError.message("\(path) 包含子节点。需要勾选“同时删除所有子节点”。尚未删除任何节点。")
            }
            plan.append((path, value.version))
            pending.append(contentsOf: children.map { NodePath.child($0, of: path) })
            guard plan.count + pending.count <= 100_000 else {
                throw ZooKeeperError.message("单次最多删除 100,000 个节点，请缩小范围。尚未删除任何节点。")
            }
        }
        return plan.reversed()
    }

    /// 从叶到根串行删除，发生错误立即停止并报告已完成的数量。
    static func delete(paths: [String], recursive: Bool, service: any ZooKeeperService) async throws -> Int {
        let plan = try await deletionPlan(paths: paths, recursive: recursive, service: service)
        var completed = 0
        for (path, version) in plan {
            do {
                try await service.delete(path, version: version)
                completed += 1
            } catch {
                throw ZooKeeperError.message("已确认删除 \(completed) 个节点，在 \(path) 处停止：\(error.localizedDescription)\n批量删除不是原子操作；若发生网络中断，当前请求的结果可能未知，请刷新确认。")
            }
        }
        return completed
    }
}
