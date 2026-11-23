# Mac App Store 打包与上传

商店版沿用现有代码及 `Resources/ZooDirector.entitlements`，只切换版本渠道、签名和分发容器。站外 DMG 继续由 `release-app.sh` 生成；商店安装包使用以下独立命令，不执行 Developer ID 公证。

## 本机签名配置

需要同一个团队的应用分发证书及安装包分发证书，并且钥匙串中都存在对应私钥。可用 `security find-identity -v` 检查。证书名称分别类似 `Apple Distribution: 姓名 (TEAMID)` 和 `3rd Party Mac Developer Installer: 姓名 (TEAMID)`。

在被 Git 忽略的 `scripts/.env` 中设置：

```sh
APPSTORE_SIGNING_IDENTITY="Apple Distribution: 你的姓名 (TEAMID)"
APPSTORE_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: 你的姓名 (TEAMID)"
APPSTORE_TEAM_ID="TEAMID"
APPSTORE_APPLE_ID="你的苹果账号邮箱"
APPSTORE_PASSWORD_ITEM="zoodirector-appstore"
```

签名身份可改用完整 SHA-1。未配置身份时，脚本只在该类证书各有一个有效候选时自动选择；有多个候选会停止，避免误用公司证书。应用与安装包证书必须属于同一团队。

证书显示不受信任时，先检查[苹果官方中间证书](https://www.apple.com/certificateauthority/)及证书签发者，不手工设为“始终信任”。Apple Distribution 和商店安装包证书通常使用 WWDR G3 信任链。

## 生成安装包

```sh
APP_VERSION=1.0.0 ./scripts/build-appstore.sh
```

脚本构建 Universal 应用，从内到外使用商店应用证书签名辅助应用和主程序，校验签名，然后使用商店安装包证书制作并检查：

```text
dist/ZooDirector-1.0.0-1-appstore.pkg
```

应用及辅助程序都包含 ARM 和 Intel 架构。打包成功只代表本地构建及签名检查通过，还需苹果服务校验和处理。首次使用私钥时，系统可能要求输入登录钥匙串密码；选择“始终允许”可复用对签名工具的授权。不要把该密码写入 `.env`。

上面的文件名以首次构建号 `1` 为例，请使用脚本实际输出的路径。未指定 `BUILD_NUMBER` 时，脚本参考本机记录、已有商店安装包及缓存应用，自动预留更高的整数构建号。记录保存在已被 Git 忽略的 `dist/.appstore-build-number`；即使构建失败也不回收号码。主程序和辅助程序使用同一个号码。

自动计数不会查询 App Store Connect。换电脑或清空全部本地记录、安装包和缓存应用后，需要用 `BUILD_NUMBER` 手动指定一次高于商店已有构建的号码，之后继续自动递增。手动指定仍按原值构建，由调用方确保未在商店使用；不会降低后续自动计数的上界。希望自动递增时，不要在 `scripts/.env` 中固定 `BUILD_NUMBER`。

商店版本必须是三段数字，不能含 `beta` 等后缀；上传前核对 App Store Connect 中的版本。构建渠道由此脚本设为 `appstore`；不要在 `.env` 中固定其他 `DISTRIBUTION_CHANNEL`。失败时保留 `dist/.appstore.*` 工作目录，不替换已有正式包。

如果苹果返回 `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE`，并指出 `previousBundleVersion: 1`，说明构建号 `1` 已被使用。保持面向用户的版本号不变，提高构建号后重新构建并签名，例如：

```sh
APP_VERSION=1.0.0 BUILD_NUMBER=2 ./scripts/build-appstore.sh
./scripts/upload-appstore.sh --upload dist/ZooDirector-1.0.0-2-appstore.pkg
```

构建号存储在包内 `CFBundleVersion`，主程序和辅助应用保持一致；只修改 `.pkg` 文件名不会改变它。此类重复构建号错误表明请求已经通过认证，不需要因此重新配置密码。

## 描述文件与 TestFlight

英文隐私政策网址为 <https://ssfyn.github.io/zoo-director/privacy.html>，可填写到 App Store Connect 的隐私政策 URL。源码保存在 `docs/privacy-policy.html`，公开网站由独立的 `gh-pages` 分支根目录提供；修改本地源码后需要同步发布该分支的 `privacy.html` 和 `index.html`。后续还需在应用内提供容易访问的隐私政策入口。

主应用及辅助应用的 `Info.plist` 均声明 `ITSAppUsesNonExemptEncryption = false`。当前 SSH 使用 macOS 自带工具，凭据使用系统钥匙串，没有内置额外加密实现；该声明用于免于重复填写加密问卷。已上传的旧构建仍需在 App Store Connect 中完成一次声明，无需为此重新上传。以后引入自有或第三方加密实现时，需重新评估这一声明。

苹果说明，原生 macOS 应用没有受限权限时，即使通过 App Store 分发也可不带 provisioning profile；TestFlight 则始终需要描述文件。目前的沙箱及网络、文件授权权限属于前一种情况。[官方说明](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

如果要使用 TestFlight，在开发者后台创建 **Mac App Store Connect** 描述文件，选择 `fan.yanan.zoodirector` 和与本机一致的应用分发证书，下载后在本地配置：

```sh
APPSTORE_PROVISIONING_PROFILE="/绝对路径/ZooDirector.provisionprofile"
```

脚本检查期限、macOS 平台、团队、明确的应用标识和签名证书，拒绝开发、Developer ID、通配符或其他应用的文件。通过后嵌入 `Contents/embedded.provisionprofile`，并仅补入描述文件授权的应用标识、团队和测试报告权限。辅助应用继续只继承主应用沙箱，无需为它另行添加受限权限。

## 校验和上传

有两种交付方式，可任选一种。

使用 Transporter：从 Mac App Store 安装苹果的 Transporter，运行下列命令，在应用中登录账号并交付安装包：

```sh
./scripts/upload-appstore.sh --transporter dist/ZooDirector-1.0.0-1-appstore.pkg
```

使用命令行：先运行一次以下命令，在脚本的隐藏输入提示中填写 App 专用密码，不将密码直接放入命令行：

```sh
./scripts/upload-appstore.sh --setup-credentials
```

脚本从 `.env` 读取 `APPSTORE_APPLE_ID`，密码仅在本次进程环境中短暂传给 `appstore-keychain.swift`，由系统钥匙串 API 保存实际值，并同时设置条目标签、服务名称和账号，结束时清除环境变量。新条目只信任当前 Xcode 的 altool 入口及实际上传程序，更新已有条目时保留原访问控制；遇到重复标签或其他服务名会停止，避免覆盖未知凭据。

本机新版 altool 的保存命令曾出现两个兼容问题：需要显式的 `--item` 和 `--app-password`，且会把 `@env:...` 原样保存，还会缺少读取所需的服务名称。因此配置入口不再调用该保存命令。已使用纯测试值实际验证系统 API 保存的是输入值而非引用，未读取真实上传密码；之前通过旧配置入口保存过的凭据需要重新配置一次。

`notarytool` 保存的公证凭据不能直接作为 `altool` 的钥匙串条目；两者需要分别配置。后续校验和上传只引用条目名称，不读取或打印密码。然后执行：

```sh
# 默认仅通过苹果服务校验。
./scripts/upload-appstore.sh dist/ZooDirector-1.0.0-1-appstore.pkg

# 显式上传前先校验，成功后上传并等待工具返回。
./scripts/upload-appstore.sh --upload dist/ZooDirector-1.0.0-1-appstore.pkg
```

脚本兼容新旧 `altool` 命令格式。多个提供商时，新版工具可通过 `APPSTORE_PROVIDER_ID` 指定提供商 UUID；可在配置认证后运行 `xcrun altool --list-providers --username 你的邮箱 --password @keychain:zoodirector-appstore` 查看。旧版工具需要更新 Xcode 或改用 Transporter。

上述操作不提交审核。上传完成后还需等待 App Store Connect 处理构建，在版本页选择构建、补齐资料及出口合规信息，再提交审核。商店包不通过 `spctl --assess` 的站外 Developer ID 策略验收，使用代码签名、安装包签名和苹果服务校验。

参考：[商店安装包上传](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)、[分发签名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)、[创建商店描述文件](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)。
