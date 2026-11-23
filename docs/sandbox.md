# 共用 App Sandbox 配置

商店和自行分发使用同一份业务代码与权限配置：`Resources/ZooDirector.entitlements`。默认开发包、ARM／Intel DMG 中的应用及 Universal 应用均启用沙箱。权限包括网络客户端、本机转发所需的监听、用户选择文件的只读访问和应用级持久书签；不添加临时文件路径或系统代理例外。

`network.server` 用于 SSH 本地端口转发，实际参数将监听地址固定为 `127.0.0.1`。主应用使用标准用户偏好保存连接、收藏和语言；密码仍使用钥匙串。`PrivacyInfo.xcprivacy` 声明自身偏好设置使用理由，不包含分析、追踪或向开发者收集数据的功能。

## SSH 文件授权及服务器身份

两种渠道统一使用以下流程：

1. 在连接设置中选择私钥。应用只持久化显示路径与只读安全作用域书签，不将私钥正文写入连接配置。旧配置能继续解码，但需要重新选择一次私钥；授权失效时同样提示重新选择。
2. 连接时在父进程中使用书签读取私钥，并在当前会话的私有目录中创建权限为 `0600` 的临时副本。子进程只继承静态沙箱，因此不能直接依赖文件选择框的动态授权。认证完成就删除副本；失败或取消时清理整个会话目录。
3. 启动系统 SSH，明确关闭系统代理、默认配置及全局主机记录，固定只使用所选私钥。加密私钥通过包内 `ZooDirectorSSHAskpass` 弹窗口令输入，口令只通过标准输出管道交回 SSH，不存入偏好、日志或环境变量。仍不支持 SSH 账户密码认证。
4. 首次连接由 SSH 提供服务器指纹，辅助程序要求用户通过可信渠道核对后确认；取消会拒绝连接。公钥变化时 SSH 拒绝连接，不自动替换。用户核实变更后，可在连接设置中“忘记服务器信任记录”，再连接核对新指纹。

服务器公钥位于应用容器的 `Library/Application Support/ZooDirector/SSH/known_hosts`；不会读写系统 `~/.ssh/known_hosts`。系统 `ssh-agent`、默认密钥自动发现及终端预先信任主机不再作为连接依赖，加密私钥改为应用内输入口令。这样两个渠道遵守相同授权规则。

辅助程序单独签名，仅包含 `app-sandbox` 与 `inherit` 两项权限；主应用从外层签名。Universal 构建同时合并主程序和辅助程序的 ARM／Intel 二进制。辅助程序等待时若 SSH 父进程退出或超过三分钟，会关闭窗口；应用内建立连接也可取消。

## 已有配置与发布

`container-migration.plist` 要求 macOS 首次创建容器时只复制同一 Bundle ID 的偏好文件，保留现有连接、收藏和语言。应用不再主动读取早期其他 Bundle ID 的偏好域；这些旧域数据只能通过显式提供的数据迁移。已有的 SSH 文件路径不能充当访问授权，需重新选择私钥。

运行 `scripts/build-app.sh` 得到的 `.app` 才带有这些权限；直接运行 SwiftPM 裸可执行文件或 `swift test` 不会自动启用 App Sandbox。`swift build --disable-sandbox` 控制的是构建过程，与最终应用的 App Sandbox 不同。

Developer ID 发布脚本重新签名时，显式携带同一份主应用权限及辅助程序继承权限。现有 GitHub Actions 继续调用此脚本，因而也会保留沙箱。商店分发使用 `build-appstore.sh` 和 `upload-appstore.sh`，同样沿用这些沙箱权限；签名、可选 provisioning profile 和上传配置见 [商店发布指南](appstore.md)。生成安装包或上传构建不代表已提交审核或审核通过。

## 验证

```sh
swift test --disable-sandbox
python3 -m unittest discover -s scripts/tests -v
./scripts/build-app.sh debug arm64
python3 Tests/SandboxProbe/run.py
```

Intel 开发机将 `arm64` 改为 `x86_64`。真实沙箱探针会直接编译生产的文件授权、SSH 隧道、主机记录与钥匙串源码，制作独立临时应用，并应用同一份沙箱权限。探针生成临时 SSH 密钥、启动仅监听回环地址的 SSH／HTTP 服务，验证沙箱确实生效、未授权的外部文件无法读取、文件书签可读取应用资源、真实 TCP 转发可传输数据、偏好和随机钥匙串条目可读写。服务与测试条目退出时清理，成功后删除临时应用和测试私钥；失败保留 `.build/sandbox-check-*` 诊断。

此探针不使用用户私钥或现有连接，也不会自动操作授权对话框；用户实际选择外部私钥、重启后的书签恢复、加密口令及首次指纹对话框仍需界面验证。Intel 切片需在 Intel Mac 上进一步运行验证。

参考：[苹果沙箱配置](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)、[文件授权](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)、[辅助程序继承](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)、[容器迁移](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container)。
