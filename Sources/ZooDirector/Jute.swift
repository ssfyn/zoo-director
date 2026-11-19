import Foundation

/// ZooKeeper 使用的大端序二进制编码器。
struct JuteWriter {
    /// 已编码的字节。
    var data = Data()

    /// 编码一个固定宽度整数。
    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    /// 编码一个布尔值。
    mutating func boolean(_ value: Bool) { data.append(value ? 1 : 0) }

    /// 编码带长度前缀的字节数组。
    mutating func buffer(_ value: Data) {
        integer(Int32(value.count))
        data.append(value)
    }

    /// 编码 UTF-8 字符串。
    mutating func string(_ value: String) { buffer(Data(value.utf8)) }

    /// 增加网络帧长度前缀。
    func framed() -> Data {
        var result = JuteWriter()
        result.buffer(data)
        return result.data
    }
}

/// 带边界检查的二进制读取器，拒绝损坏或过大的服务端响应。
struct JuteReader {
    /// 当前读取的字节。
    let data: Data
    /// 下一个字段的字节偏移。
    var offset = 0

    /// 读取固定宽度的大端序整数，避免未对齐的内存访问。
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset <= data.count - size else { throw ZooKeeperError.message("服务端响应不完整。") }
        var value: T = 0
        for byte in data[offset..<(offset + size)] { value = (value << 8) | T(truncatingIfNeeded: byte) }
        offset += size
        return value
    }

    /// 读取有限长度的缓冲区，将协议中的空值表示为空数据。
    mutating func buffer() throws -> Data {
        let length = try integer(Int32.self)
        if length == -1 { return Data() }
        guard length >= 0, Int(length) <= data.count - offset else {
            throw ZooKeeperError.message("服务端返回了无效的数据长度。")
        }
        defer { offset += Int(length) }
        return data.subdata(in: offset..<(offset + Int(length)))
    }

    /// 读取字符串，对非法 UTF-8 显式报错。
    mutating func string() throws -> String {
        guard let value = String(data: try buffer(), encoding: .utf8) else {
            throw ZooKeeperError.message("节点名称不是有效的 UTF-8。")
        }
        return value
    }

    /// 按协议顺序读取节点状态。
    mutating func stat() throws -> NodeStat {
        try NodeStat(
            createdZXID: integer(), modifiedZXID: integer(), created: integer(), modified: integer(),
            version: integer(), childVersion: integer(), aclVersion: integer(),
            ephemeralOwner: integer(), dataLength: integer(), childCount: integer(), childrenZXID: integer()
        )
    }
}
