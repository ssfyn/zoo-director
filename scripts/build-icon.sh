#!/bin/zsh
# 将矢量源文件渲染为预览图，并生成包含所有标准尺寸的 macOS 应用图标。
set -euo pipefail
cd "$(dirname "$0")/.."
# 加载本机配置并导出变量，供当前脚本及其启动的子进程使用。
if [[ -f scripts/.env ]]; then
    set -a
    source scripts/.env
    set +a
fi
icon_work_dir="$(mktemp -d "${TMPDIR:-/tmp/}zoodirector-icon.XXXXXX")"
trap 'rm -rf "$icon_work_dir"' EXIT
mkdir -p "$icon_work_dir/ZooDirector.iconset"
swift -module-cache-path "$icon_work_dir/module-cache" - <<'SWIFT'
import AppKit

// 使用系统矢量渲染器从源文件生成带透明通道的高清预览。
guard let image = NSImage(contentsOfFile: "Resources/ZooDirector.svg"),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("无法读取图标源文件或创建绘图上下文") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:])
else { fatalError("无法编码图标预览") }
try png.write(to: URL(fileURLWithPath: "Resources/ZooDirector.png"))
SWIFT

# 同时导出普通与高分辨率版本，覆盖程序坞、访达和应用切换器。
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/ZooDirector.png --out "$icon_work_dir/ZooDirector.iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" Resources/ZooDirector.png --out "$icon_work_dir/ZooDirector.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# 按 ICNS 格式封装各尺寸的 PNG，避免依赖系统图标转换服务。
swift -module-cache-path "$icon_work_dir/module-cache" - "$icon_work_dir/ZooDirector.iconset" <<'SWIFT'
import Foundation

/// 将长度编码为 ICNS 使用的大端四字节整数。
func encodedLength(_ length: Int) -> Data {
    var value = UInt32(length).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let variants = [
    ("icp4", "16x16"), ("icp5", "32x32"),
    ("ic07", "128x128"), ("ic08", "256x256"), ("ic09", "512x512"),
    ("ic11", "16x16@2x"), ("ic12", "32x32@2x"),
    ("ic13", "128x128@2x"), ("ic14", "256x256@2x"), ("ic10", "512x512@2x")
]
var payload = Data()
for (type, name) in variants {
    let png = try Data(contentsOf: directory.appendingPathComponent("icon_\(name).png"))
    payload.append(Data(type.utf8))
    payload.append(encodedLength(png.count + 8))
    payload.append(png)
}
var icon = Data("icns".utf8)
icon.append(encodedLength(payload.count + 8))
icon.append(payload)
try icon.write(to: URL(fileURLWithPath: "Resources/ZooDirector.icns"))
SWIFT
printf '图标已生成：Resources/ZooDirector.png、Resources/ZooDirector.icns\n'
