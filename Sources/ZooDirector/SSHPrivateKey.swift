import Foundation

/// 私钥仅保存文件授权；向继承静态沙箱的 SSH 子进程传递临时副本。
enum SSHPrivateKey {
    /// 读取用户明确授权的普通文件，限制大小并在结束时释放访问授权。
    static func read(bookmark: Data?) throws -> Data {
        guard let bookmark else {
            throw ZooKeeperError.message("Choose the SSH private key again to authorize file access.")
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else {
                throw ZooKeeperError.message("Choose the SSH private key again to authorize file access.")
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_048_576 else {
                throw ZooKeeperError.message("Choose a nonempty SSH private key file no larger than 1 MiB.")
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else {
                throw ZooKeeperError.message("Choose a nonempty SSH private key file no larger than 1 MiB.")
            }
            return data
        } catch let error as ZooKeeperError {
            throw error
        } catch {
            throw ZooKeeperError.message("The SSH private key cannot be read. Choose it again to renew access.")
        }
    }

    /// 为选择框返回的文件保存只读持久授权，不把私钥内容放入连接配置。
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 在会话私有目录中创建仅当前用户可读写的副本，断开时随目录删除。
    static func stage(bookmark: Data?, in directory: URL) throws -> URL {
        let data = try read(bookmark: bookmark)
        let url = directory.appendingPathComponent("identity")
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ZooKeeperError.message("Cannot prepare the SSH private key for this connection.")
        }
        return url
    }
}
