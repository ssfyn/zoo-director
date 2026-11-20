# 自动构建与发布

工作流位于 `.github/workflows/release.yml`。正式包始终使用 Developer ID 签名和 Apple 公证；缺少凭据时明确失败，不会退回临时签名后上传。

## 一次性配置

先将工作流和脚本提交并推送到 `main`，再创建包含这些文件的版本标签。

在 GitHub 仓库的 **Settings → Secrets and variables → Actions → Repository secrets** 配置：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application 证书及私钥导出的 `.p12`，经过 Base64 编码 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的非空密码 |
| `MACOS_SIGNING_IDENTITY` | 证书完整名称，如 `Developer ID Application: Your Name (TEAMID)`，也可填写 SHA-1 指纹 |
| `APPLE_API_KEY_P8_BASE64` | 用于公证的 App Store Connect **团队 API Key** 的 `.p8` 文件，经过 Base64 编码 |
| `APPLE_API_KEY_ID` | 上述 API Key 的 Key ID |
| `APPLE_API_ISSUER_ID` | 上述团队 API Key 的 Issuer ID |

从“钥匙串访问”导出同时包含私钥的 Developer ID Application 身份，证书需要有效的 Apple Developer Program 会员资格。这里不使用 Mac App Distribution 证书。API Key 需要有公证权限，当前脚本使用带 Issuer ID 的团队密钥。

可在本机复制 Base64 到剪贴板，再粘贴到 GitHub Secret。不要将证书、私钥或密码提交到仓库或贴进工作流：

```sh
base64 -i /path/to/DeveloperID.p12 | tr -d '\n' | pbcopy
base64 -i /path/to/AuthKey_KEYID.p8 | tr -d '\n' | pbcopy
```

上传 Release 使用工作流自带的 `GITHUB_TOKEN`，无需另建个人 Token。仓库或组织策略需允许 Actions 使用 `contents: write` 权限。CI 忽略本机 `scripts/.env`，只使用显式传入的参数与 Secrets。

## 发布已有 Release

在 GitHub 创建并发布带标签的 Release，例如 `v1.0.0`。仅保存草稿不会触发自动构建。

工作流会：

1. 校验标签，并检出该标签对应的提交。
2. 在 `macos-26`（ARM）和 `macos-26-intel`（Intel）上分别测试，固定使用 Xcode 26.6。
3. 生成同一版本和构建号的应用，签名、公证并制作两个 DMG。
4. 两个任务都成功后，将文件上传到对应 Release 的 Assets。

示例产物：

```text
ZooDirector-1.0.0-arm64.dmg
ZooDirector-1.0.0-x86_64.dmg
```

CI 每个架构只生成一个 DMG，不额外上传 Universal 应用。应用和 DMG 各公证一次，两种架构合计四次公证。

如果某个任务失败，发行版上传任务不会执行；已成功构建的 DMG 可在该次 Actions 的 Artifacts 下载，保留 7 天。修复问题后可重新运行。公证服务的响应时间不固定，单个构建任务最长运行 90 分钟。

## 不可变 Release：先构建草稿，再发布

启用 GitHub 不可变 Release 时，必须先上传附件再发布：

1. 创建并推送标签 `v1.0.0`，暂不发布 Release。
2. 打开 **Actions → Release macOS → Run workflow**，选择含最新工作流的 `main`，输入标签 `v1.0.0`。
3. 工作流构建完成后创建或更新该标签的草稿 Release，并上传两个 DMG。
4. 检查附件和发布说明，再手动发布草稿。

发布草稿触发的第二次工作流会检测完整的同版本附件并跳过重复构建。已经锁定且缺少附件的 Release 无法补传，需要使用新版本标签。手动重建可以替换尚未锁定的同名资产，不会修改已经锁定的资产。

## 版本参数

构建脚本统一接受：

| 参数 | 本地默认 | Actions Release |
| --- | --- | --- |
| `APP_VERSION` | `dev` | 去掉标签前缀 `v`，例如 `1.0.0` |
| `BUILD_NUMBER` | `1` | `运行编号.重试次数`，例如 `42.1` |
| `DISTRIBUTION_CHANNEL` | `dev` | `github` |

本地缺省构建的“关于”显示 `dev`，不以 Debug / Release 优化模式判断发行版本。正式包显示版本和构建号，例如 `1.0.0 (42.1)`。预发布标签如 `v1.1.0-beta.1` 显示完整标记，Apple 标准版本字段仍保存 `1.1.0`。

版本在签名前写入 `Info.plist`：

- `CFBundleShortVersionString`：三段数字；本地为 `0.0.0`。
- `CFBundleVersion`：符合 Apple 格式的构建号。
- `ZooDirectorDisplayVersion`：`dev` 或完整发行版本。
- `ZooDirectorDistributionChannel`：`dev`、`github` 或预留的 `appstore`。

参数校验在编译前执行，非法标签、版本和构建号会明确失败。构建号首段上限为 9999；若运行编号将超过该范围，应调整生成策略并继续保持发布构建号递增。工作流重命名会改变运行编号序列，未来 App Store 上传应使用统一管理且未重复的构建号。

本机显式打包仍可使用已有钥匙串：

```sh
APP_VERSION=1.0.0 BUILD_NUMBER=42.1 ./scripts/release-app.sh arm64 x86_64
```

`release-app.sh` 默认渠道为 `github`，要求显式版本；签名身份及公证 profile 的配置方式不变。未指定架构时仍保留原有本机发布行为：两个 DMG 加一个 Universal 应用。

`appstore` 目前仅预留版本元信息，正式版本不能含预发布标记。现有 Developer ID 发布脚本会拒绝该渠道；商店签名、沙箱、描述文件、TestFlight / App Store Connect 上传需要后续独立接入。

## 凭据与验证

每个构建任务使用独立临时钥匙串，导入后立即删除临时 `.p12` 和 `.p8` 文件，任务结束时恢复钥匙串搜索列表并删除临时钥匙串。不要把 `dist/.release.*` 整个目录当作公开附件上传。

本地验证无需发布凭据：

```sh
python3 -m unittest discover -s scripts/tests -v
swift test --disable-sandbox
zsh -n scripts/build-app.sh scripts/release-app.sh
```

真正的签名、公证及上传还需要配置上述 Secrets 并在 GitHub 执行。参考 [GitHub 发布事件](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release)、[不可变 Release](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases) 与 [Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
