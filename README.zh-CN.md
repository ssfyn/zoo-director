# ZooDirector

[English](README.md) | 简体中文

Finder 风格的 macOS 原生 ZooKeeper 客户端，使用 Swift、SwiftUI 和 AppKit 构建，无 JVM 或 WebView 依赖。

![ZooDirector 应用截图](docs/screenshot.png)

## 功能

- 多连接管理、连接测试、digest 认证和 SSH 隧道，各连接独立保留浏览与编辑状态。
- 树状浏览，无分页展示当前层节点；支持路径跳转、收藏和列排序。
- 查看节点内容、创建时间、修改时间、子节点数及临时节点信息。
- 搜索当前目录或包含子目录；当前目录筛选保留展开与收起操作。
- 编辑文本、创建持久／临时节点、多选删除及递归删除确认。
- Watch 实时刷新，兼容 ZooKeeper 3.4 / 3.5 单次监听与 3.6+ 持久监听。
- 简体中文与英文界面，可在首选项中切换。

## 构建运行

需要 macOS 14+、Xcode 或包含 macOS SDK 的 Swift 工具链。已在 Apple Silicon、Swift 6.4.2 下验证。

```sh
git clone git@github.com:ssfyn/zoo-director.git
cd zoo-director
./scripts/build-app.sh
open ".build/ZooDirector.app"
```

开发构建使用 `./scripts/build-app.sh debug`，也可用 Xcode 打开 `Package.swift`。

构建始终覆盖同一个应用包，重启应用后加载更新。目前生成本机架构的临时签名应用，尚未公证。应用标识为 `fan.yanan.zoodirector`。

## 使用

添加 `host:port` 格式的连接后，点击“连接”进入浏览。地址栏支持绝对路径；双击节点进入，双击 `..` 返回上一级。

点击 `+` 新增节点，选中节点后在检查器编辑。使用 `⌘` 点选或 `Shift` 连选，再点击垃圾桶删除；非空目录需勾选“同时删除所有子节点”。启用 digest 时，新节点仅允许当前认证身份访问；未启用时使用 `world:anyone` 开放权限。批量删除逐个执行，失败即停止，已删除内容不会回滚。

digest 用户名保存在连接配置中，密码保存在 macOS 钥匙串；编辑时不修改密码即可保留原密码。测试连接确认身份提交成功，实际读写权限由节点 ACL 决定。digest 不加密网络传输，可配合 SSH 隧道。

SSH 仅支持密钥认证，ZooKeeper 地址需为 SSH 服务器可达的地址。首次使用前应在终端连接并核对 SSH 主机指纹；加密私钥需先加入 ssh-agent。

常用快捷键：`⌘N` 添加连接、`⇧⌘G` 跳转路径、`⌘R` 刷新、`⇧⌘N` 新增节点、`⌘⌫` 删除所选节点、`⌘S` 保存、`⌘,` 首选项。

## 当前限制

- 不支持 SASL、TLS、chroot、集群故障切换、自动重连和 ACL 编辑。
- 搜索仅按节点名称；递归搜索有扫描与结果数量上限，达到时会提示。
- 超过 256 KiB 或非 UTF-8 数据仅提供只读预览；写入上限为 1,000,000 字节。
- 保存按数据版本校验，不自动重试写入；网络异常后应刷新确认结果。
- 当前层名称完整加载，元信息按需读取；超大目录仍会占用相应内存。

## 测试

```sh
swift test --disable-sandbox
```

未配置环境的真实服务测试会跳过。设置 `ZOODIRECTOR_TEST_ENDPOINT` 会启用实际读写测试，只能用于隔离实例，并需预先创建可写节点 `/zoodirector-test`。

更多验证记录见 [docs/validation.md](docs/validation.md)。
