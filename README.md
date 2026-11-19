# Zoo Director

一个面向 macOS 的原生 ZooKeeper GUI 客户端，采用 Finder 风格的目录浏览、树表格和节点检查器。使用 Swift、SwiftUI、AppKit 与 Network.framework 构建，无 JVM、WebView 或第三方运行依赖。

## 功能

- **连接管理**：保存和编辑多个连接，支持测试连接、取消连接及手动断开。启动和保存配置不会自动建立会话。多个活动连接各自保留浏览位置、历史、展开状态、搜索、未保存编辑和监听。
- **目录浏览**：从任意绝对路径开始查看，支持前进、后退、上一级、回到根目录和收藏。`..` 单击查看当前目录数据，双击或按回车进入上一级。
- **树状查看**：逐层展开和收起，完整展示当前层名称，无分页。表格显示创建时间、修改时间、子节点数量和临时节点标识，支持列排序。
- **范围搜索**：当前目录按名称本地筛选，结果保留展开／收起操作；展开后完整展示子节点。包含子目录的搜索由用户显式启动，支持进度、取消和资源上限提示，结果使用相对路径区分同名节点。
- **节点读写**：查看节点数据、版本和所属会话，编辑 UTF-8 文本，按读取到的版本保存，保护未保存内容。
- **新增和删除**：创建持久或临时节点，填写初始内容；支持多选删除、递归删除确认及版本检查。
- **实时更新**：监听当前目录、展开分支、屏幕附近节点和检查器目标，合并事件并局部刷新。兼容旧版单次 Watch 与新版持久 Watch。
- **SSH 隧道**：通过系统 OpenSSH 访问跳板机可达的 ZooKeeper，支持默认密钥、指定私钥和 ssh-agent。
- **中英双语**：在“Zoo Director → 首选项…”中选择自动、English 或简体中文，切换立即生效并保留当前会话和编辑内容。

## 环境要求

- macOS 14 或更新版本。
- Xcode 或包含 macOS SDK 的 Swift 工具链。本项目在 Apple Silicon、Apple Swift 6.4.2 下完成构建验证；`Package.swift` 使用 Swift 6 工具版本。
- 可访问的 ZooKeeper 单服务器地址，格式为 `host:port`；IPv6 使用 `[地址]:端口`。
- 使用 SSH 隧道时，需要系统 `/usr/bin/ssh` 和可用的公钥认证。

## 构建与启动

```sh
git clone git@github.com:ssfyn/zoo-director.git
cd zoo-director
./scripts/build-app.sh
open ".build/Zoo Director.app"
```

开发构建：

```sh
./scripts/build-app.sh debug
open ".build/Zoo Director.app"
```

也可以用 Xcode 打开 `Package.swift` 进行开发。构建脚本始终覆盖同一个 `.build/Zoo Director.app`，不会生成新的预览应用；重新构建后，退出并再次打开应用即可加载更新。

脚本生成本机架构的应用并使用临时签名，尚未提供 Developer ID 签名、公证或通用架构发行包。

## 使用方式

### 连接与导航

1. 添加连接，填写 ZooKeeper 地址；名称可留空，界面会以地址显示。
2. 可先使用“测试连接”验证尚未保存的配置。测试结束会关闭临时会话，不会保存配置或切换正式连接。
3. 保存配置后点击“连接”。侧栏单击连接用于查看或切换其页面，不会自动建立新会话。
4. 使用地址栏直接进入路径，或双击节点进入。右键节点可复制路径、收藏或执行节点操作。

每个连接独立保存收藏。关闭连接会释放会话和隧道，并保留本机配置；删除连接需确认，只删除对应的本机配置及收藏，不删除服务端节点。旧版 Canopy 的连接及收藏会在首次使用时迁移，已有 Zoo Director 配置不会被覆盖。

### 搜索

**当前目录**只筛选这一层的节点名称，不递归发起搜索请求。匹配节点保留展开按钮，手动展开后显示完整后代；修改或清空关键词保留已有展开状态。

**包含子目录**以当前路径为起点，点击“搜索”或按回车启动。搜索只读取节点名称，不搜索数据内容；结果以相对路径显示。最多并发读取 4 个目录，扫描 2,000 个目录、100,000 个节点和 64 层，返回最多 2,000 条结果。达到上限时会提示结果不完整；无权限或已消失的目录计入跳过数量。

### 新增、编辑与删除

- 点击地址栏右侧 `+`，在当前目录新增节点；右键节点可以在其内部新增。支持初始 UTF-8 文本、持久节点和临时节点。新节点使用 `world:anyone` 开放权限；临时节点随创建它的会话结束自动删除，不能包含子节点。
- 选中节点后在检查器编辑，保存前需确认。写入使用读取时的数据版本，其他客户端修改过的数据不会被直接覆盖。
- 使用 `⌘` 点选或 `Shift` 连选，再点击垃圾桶或右键删除。确认窗口列出目标路径，默认只删除空节点；删除非空目录需要勾选“同时删除所有子节点”。根节点和 `..` 不能删除。

删除前会合并父子重叠目标并预检整批目录和数据版本，再从叶到根逐个删除，单次最多 100,000 个节点。**批量删除不是原子操作**：遇到错误即停止并报告已确认删除数量，已完成的操作不会回滚。写入不自动重试；网络中断导致结果不明确时，应先刷新确认再决定后续操作。

### SSH 隧道

勾选“使用 SSH 隧道”，填写 SSH 主机、端口、用户名和可选私钥路径。ZooKeeper 地址应填写 **SSH 服务器能够访问的地址**，例如 `127.0.0.1:2181` 或 `zk.internal:2181`。

认证使用默认密钥、指定私钥或 ssh-agent，不提供密码和私钥口令输入。加密私钥可先在终端加入代理：

```sh
ssh-add /path/to/private-key
```

应用严格校验主机密钥。首次使用前，请在终端连接同一 SSH 主机并核对指纹，例如：

```sh
ssh -p 2222 operator@bastion.example.com
```

应用不读取 `~/.ssh/config` 中的别名、跳板链或附加转发设置，请使用表单配置实际地址。仅保存 SSH 配置及私钥路径，不复制密钥内容；本地转发只监听 `127.0.0.1`。断开、修改或删除对应连接及正常退出时会回收独占隧道，切换查看其他连接时保持已有隧道。

### 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘N` | 添加连接 |
| `⌘,` | 首选项 |
| `⇧⌘G` | 聚焦路径栏 |
| `⌘[` / `⌘]` | 后退 / 前进 |
| `⌘↑` | 上一级 |
| `⌘R` | 刷新 |
| `⇧⌘N` | 新增节点 |
| `⌘⌫` | 删除所选节点，先确认 |
| `⌘S` | 保存节点数据，先确认 |
| `←` / `→` | 收起 / 展开当前分支 |
| `Return` | 打开选中节点或 `..` |

## 兼容性与性能边界

当前不支持 ZooKeeper digest / SASL 认证、TLS、chroot、集群地址列表及故障切换、自动重连、完整会话恢复、ACL 编辑和节点数据内容搜索。断开后需要手动重新连接。

- ZooKeeper 3.4 / 3.5 使用单次 Watch，事件触发后重新注册；服务端明确为 3.6+ 时使用持久 Watch。版本查询失败或不可用时选择兼容模式，不向主会话发送未知操作码试探能力。
- 事件按约 100 ms 合并，刷新保留展开状态；检查器有未保存内容时保留编辑并提示变化。重新注册监听后会重同步，展示最终状态，不保证记录每一次中间变化。
- 旧版服务器不能主动移除已注册的单次 Watch；取消关注后停止重新注册，已有监听随事件触发或会话结束释放。
- 原生表格复用行视图，只为屏幕附近节点读取元信息，最多并发 8 个状态请求。按时间或数量排序会补齐当前展示范围的状态，不扫描隐藏后代。
- `getChildren` 仍一次返回当前层完整名称。名称数组、缓存及展开状态占用内存，无分页不代表任意规模下内存恒定。
- 选中节点后才下载数据。超过 256 KiB 或无法解码为 UTF-8 的数据只显示前 512 字节的十六进制预览；响应帧上限 16 MiB，写入上限 1,000,000 字节。

20,000 节点压力样本仅存在于测试夹具中，不随应用提供演示空间，也不代表真实网络性能基准。更多验证条件和历史记录见 [docs/validation.md](docs/validation.md)。

## 开发与测试

运行默认测试：

```sh
swift test --disable-sandbox
```

未配置集成测试环境时，需要真实服务的测试会跳过。部分 SSH 生命周期测试需要本机回环端口权限。受限环境中，可以将 `CLANG_MODULE_CACHE_PATH` 和 `SWIFTPM_MODULECACHE_OVERRIDE` 指向可写目录。

### ZooKeeper 集成测试

仅使用可写的隔离实例。`ZOODIRECTOR_TEST_ENDPOINT` 会启用真实写入测试：基础测试修改预先存在的 `/zoodirector-test`，Watch 和节点操作测试分别在 `/zoodirector-watch-<UUID>`、`/zoodirector-mutations-<UUID>` 下创建、修改和删除测试节点。不要指向业务实例。

```sh
ZOODIRECTOR_TEST_ENDPOINT=127.0.0.1:2181 swift test --disable-sandbox
```

`ZOODIRECTOR_EXPECT_WATCH_MODE` 可设置为 `standard` 或 `persistent`，用于检查真实 Watch 测试采用的策略。旧服务端只读连接稳定性测试可单独运行：

```sh
ZOODIRECTOR_LEGACY_TEST_ENDPOINT=127.0.0.1:2181 \
  swift test --disable-sandbox --filter LegacyWatchTests
```

### SSH 集成测试

真实 SSH 只读测试需设置 `ZOODIRECTOR_TEST_SSH_HOST`、`ZOODIRECTOR_TEST_SSH_USER` 和 `ZOODIRECTOR_TEST_SSH_TARGET`；可选 `ZOODIRECTOR_TEST_SSH_PORT`（默认 `22`）与 `ZOODIRECTOR_TEST_SSH_KEY`。`TARGET` 是 SSH 服务器可访问的 ZooKeeper 地址。

### 目录结构

| 路径 | 内容 |
| --- | --- |
| `Sources/ZooDirector/` | 界面、连接工作区、树模型及 ZooKeeper 协议实现 |
| `Sources/ZooDirector/Resources/Localization/` | 简体中文与英文语言目录 |
| `Tests/ZooDirectorTests/` | 单元测试、集成测试与隔离演示夹具 |
| `Resources/` | SVG 图标源文件、PNG 预览及 ICNS 资源 |
| `scripts/build-app.sh` | 构建并签名本地应用 |
| `scripts/build-icon.sh` | 从 SVG 重新生成 PNG 与 ICNS |
| `docs/validation.md` | 验证记录与性能边界 |

修改图标后运行 `zsh scripts/build-icon.sh`，再重新构建应用。应用标识为 `app.zoodirector.zookeeper`，Swift 包和可执行文件名为 `ZooDirector`。
