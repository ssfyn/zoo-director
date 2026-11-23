#!/bin/zsh
# 构建同一业务代码的通用商店应用，签名后生成可上传的安装包。
set -euo pipefail
cd "$(dirname "$0")/.."
# 本机加载私有配置；持续集成仅使用显式环境变量。
if [[ "${GITHUB_ACTIONS:-false}" != true && -f scripts/.env ]]; then
    set -a
    source scripts/.env
    set +a
fi

# 显示商店打包参数，不读取钥匙串或执行上传。
show_help() {
    cat <<'HELP'
用法：APP_VERSION=1.0.0 ./scripts/build-appstore.sh

默认构建 Universal 应用，输出 dist/ZooDirector-版本号-构建号-appstore.pkg。
只生成安装包，不上传、不提交审核、不执行 Developer ID 公证。

可选环境变量：
  BUILD_NUMBER                  手动指定构建号；省略时按本机记录自动递增。
  APPSTORE_SIGNING_IDENTITY      商店应用证书完整名称或 SHA-1。
  APPSTORE_INSTALLER_IDENTITY    商店安装包证书完整名称或 SHA-1。
  APPSTORE_TEAM_ID               要求使用的团队标识。
  APPSTORE_PROVISIONING_PROFILE  Mac App Store Connect 描述文件路径。

未指定签名身份时只允许唯一的商店证书候选；两个证书必须属于同一团队。
目前无受限权限时描述文件可省略；使用 TestFlight 时必须配置描述文件。
自动号码保存在 dist/.appstore-build-number，失败也不回收号码。
换电脑或清理全部记录和产物后，需手动指定一个高于商店现有记录的号码。
HELP
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    show_help
    exit 0
fi
if (( $# != 0 )); then
    show_help >&2
    exit 1
fi
export DISTRIBUTION_CHANNEL=appstore
python3 scripts/build-metadata.py --validate-only
for tool in python3 security codesign productbuild pkgutil ditto lipo plutil; do
    command -v "$tool" >/dev/null
done
mkdir -p dist
work_dir="$(mktemp -d "$PWD/dist/.appstore.XXXXXX")"

# 失败时保留应用与构建参数；全部成功后才替换正式安装包。
report_exit() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        printf '商店打包未完成，诊断目录：%s\n' "$work_dir" >&2
    fi
}
trap report_exit EXIT
python3 scripts/appstore-signing.py "$work_dir"
application_identity="$(plutil -extract application raw -o - "$work_dir/signing.json")"
installer_identity="$(plutil -extract installer raw -o - "$work_dir/signing.json")"
profile="$(plutil -extract profile raw -o - "$work_dir/signing.json")"
# 在实际编译前预留号码，整个通用构建及其辅助应用继承同一号码。
export BUILD_NUMBER="$(python3 scripts/appstore-build-number.py)"
printf '本次商店构建号：%s\n' "$BUILD_NUMBER"
./scripts/build-app.sh release universal
app_dir="$work_dir/ZooDirector.app"
ditto .build/apps/universal/ZooDirector.app "$app_dir"
if [[ -n "$profile" ]]; then
    cp "$profile" "$app_dir/Contents/embedded.provisionprofile"
fi
# 辅助应用仅继承沙箱，不向它添加需要单独描述文件的应用标识权限。
helper_dir="$app_dir/Contents/Helpers/ZooDirectorSSHAskpass.app"
codesign --force --options runtime --timestamp --sign "$application_identity" \
    --entitlements Resources/SSHAskpass.entitlements "$helper_dir"
codesign --force --options runtime --timestamp --sign "$application_identity" \
    --entitlements "$work_dir/appstore.entitlements" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_dir/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw -o - "$app_dir/Contents/Info.plist")"
channel="$(plutil -extract ZooDirectorDistributionChannel raw -o - "$app_dir/Contents/Info.plist")"
if [[ "$channel" != appstore ]]; then
    printf '构建渠道被本地配置覆盖，请移除 scripts/.env 中的 DISTRIBUTION_CHANNEL 设置后重试。\n' >&2
    exit 1
fi
productbuild --component "$app_dir" /Applications --sign "$installer_identity" \
    "$work_dir/distribution.pkg"
pkgutil --check-signature "$work_dir/distribution.pkg"
output_file="$PWD/dist/ZooDirector-${version}-${build}-appstore.pkg"
mv -f "$work_dir/distribution.pkg" "$output_file"
printf '商店上传包：%s\n构建记录：%s\n' "$output_file" "$work_dir"
