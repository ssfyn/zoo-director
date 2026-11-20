#!/bin/zsh
# 发布两种架构的磁盘映像及通用应用，完成签名、公证、票据附加及验证。
set -euo pipefail
cd "$(dirname "$0")/.."
# 加载本机配置并导出变量，供当前脚本及其启动的子进程使用。
if [[ "${GITHUB_ACTIONS:-false}" != true && -f scripts/.env ]]; then
    set -a
    source scripts/.env
    set +a
fi

# 签名身份必须通过本机配置或环境变量指定，避免误用其他团队证书。
signing_identity="${SIGNING_IDENTITY:-}"
notary_profile="${NOTARY_PROFILE:-zoodirector-notary}"
# CI 使用独立临时钥匙串，本机未指定时继续使用默认钥匙串。
notary_keychain_args=()
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    notary_keychain_args=(--keychain "$NOTARY_KEYCHAIN")
fi
work_dir=""
target_arch=""

# 显示参数说明，不读取钥匙串或提交公证。
show_help() {
    cat <<'HELP'
用法：
  APP_VERSION=1.0.0 ./scripts/release-app.sh
  APP_VERSION=1.0.0 ./scripts/release-app.sh arm64
  APP_VERSION=1.0.0 ./scripts/release-app.sh x86_64
  APP_VERSION=1.0.0 ./scripts/release-app.sh universal
  # 未配置 scripts/.env 时，也可通过环境变量指定：
  APP_VERSION=1.0.0 SIGNING_IDENTITY="Developer ID Application: 姓名 (TEAMID)" ./scripts/release-app.sh

本机配置：
  本机构建和发布脚本自动加载 scripts/.env；GitHub Actions 不加载。
  文件使用 shell 赋值语法；同名变量以文件中的赋值为准。

环境变量：
  APP_VERSION      必填，发行版本，例如 1.0.0 或 1.1.0-beta.1。
  BUILD_NUMBER     构建号，默认 1。
  DISTRIBUTION_CHANNEL  默认 github；App Store 尚需独立的签名和上传流程。
  SIGNING_IDENTITY  必填，Developer ID Application 完整名称或 SHA-1。
  NOTARY_PROFILE   钥匙串公证凭据名称，默认 zoodirector-notary。

输出：dist/ZooDirector-版本号-arm64.dmg、ZooDirector-版本号-x86_64.dmg
      dist/ZooDirector-版本号-universal.app
默认发布全部三种产物，也可指定 arm64、x86_64 或 universal。
公证需要网络，等待时间由苹果服务决定。
失败时保留 dist/.release.* 中的应用、提交结果及诊断日志。
HELP
}

# 报告失败阶段并保留工作目录，便于排查或继续查询公证结果。
report_exit() {
    local exit_code=$?
    if (( exit_code != 0 )) && [[ -n "$work_dir" ]]; then
        printf '发布未完成，工作文件保留在：%s\n' "$work_dir" >&2
    fi
}

# 检查工具、明确的签名身份及钥匙串凭据，避免构建后才发现缺少配置。
check_requirements() {
    local tool identities line
    for tool in swift codesign security xcrun ditto plutil spctl lipo hdiutil; do
        command -v "$tool" >/dev/null || {
            printf '缺少所需工具：%s\n' "$tool" >&2
            return 1
        }
    done
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
    if [[ -z "$signing_identity" ]]; then
        printf '请在 scripts/.env 或环境变量中通过 SIGNING_IDENTITY 指定 Developer ID Application 证书。\n' >&2
        return 1
    fi
    identities="$(security find-identity -v -p codesigning)"
    # 只接受有效的应用分发身份，完整匹配名称或指纹，拒绝临时签名。
    for line in "${(@f)identities}"; do
        if [[ "$line" == *'"Developer ID Application: '* &&
              ( "$line" == *"\"${signing_identity}\"" ||
                "$line" == *" ${signing_identity} \""* ) ]]; then
            printf '检查公证凭据：%s\n' "$notary_profile"
            xcrun notarytool history --keychain-profile "$notary_profile" "${notary_keychain_args[@]}" \
                --output-format json >/dev/null
            return 0
        fi
    done
    printf '找不到有效的 Developer ID Application 身份：%s\n' "$signing_identity" >&2
    printf '请运行 security find-identity -v -p codesigning 检查。\n' >&2
    return 1
}

# 按目标架构构建并核对实际二进制架构，在独立目录中签名。
build_and_sign() {
    local actual_arch
    ./scripts/build-app.sh release "$target_arch"
    ditto ".build/apps/$target_arch/ZooDirector.app" "$work_dir/ZooDirector.app"
    actual_arch="$(lipo -archs "$work_dir/ZooDirector.app/Contents/MacOS/ZooDirector")"
    if [[ "$target_arch" == universal ]]; then
        lipo -verify_arch arm64 x86_64 "$work_dir/ZooDirector.app/Contents/MacOS/ZooDirector"
    elif [[ "$actual_arch" != "$target_arch" ]]; then
        printf '二进制架构不符：预期 %s，实际 %s\n' "$target_arch" "$actual_arch" >&2
        return 1
    fi
    codesign --force --options runtime --timestamp \
        --sign "$signing_identity" "$work_dir/ZooDirector.app"
    codesign --verify --deep --strict --verbose=2 "$work_dir/ZooDirector.app"
}

# 读取公证响应中的字段；网络失败或响应不完整时返回空值供上层处理。
read_notary_field() {
    plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

# 提交指定归档，仅在苹果明确接受后继续；应用和磁盘映像分别保留记录。
notarize_archive() {
    local archive="$1" label="$2"
    local result_file="$work_dir/notary-${label}-result.json"
    local submit_failed=0 submission_id notary_status
    printf '提交苹果公证（%s）并等待结果……\n' "$label"
    xcrun notarytool submit "$archive" \
        --keychain-profile "$notary_profile" "${notary_keychain_args[@]}" --wait --output-format json \
        > "$result_file" || submit_failed=1
    submission_id="$(read_notary_field id "$result_file")"
    notary_status="$(read_notary_field status "$result_file")"
    if (( submit_failed == 0 )) && [[ "$notary_status" == Accepted ]]; then
        printf '公证成功，提交编号：%s\n' "$submission_id"
        return 0
    fi
    printf '公证未通过或提交失败，状态：%s\n' "${notary_status:-未知}" >&2
    if [[ -n "$submission_id" ]]; then
        printf '提交编号：%s\n' "$submission_id" >&2
        xcrun notarytool log "$submission_id" "$work_dir/notary-${label}-log.json" \
            --keychain-profile "$notary_profile" "${notary_keychain_args[@]}" || true
    fi
    return 1
}

# 使用临时压缩包公证应用并附加票据，确保脱离磁盘映像后也能验证。
notarize_app() {
    local app_dir="$work_dir/ZooDirector.app"
    ditto -c -k --keepParent "$app_dir" "$work_dir/notary-upload.zip"
    notarize_archive "$work_dir/notary-upload.zip" app
    xcrun stapler staple "$app_dir"
    xcrun stapler validate "$app_dir"
    codesign --verify --deep --strict --verbose=2 "$app_dir"
    spctl --assess --type execute --verbose=2 "$app_dir"
}

# 将已附加票据的应用和安装快捷方式制作成只读压缩磁盘映像并公证。
create_dmg() {
    local image="$work_dir/distribution.dmg"
    mkdir -p "$work_dir/dmg-content"
    ditto "$work_dir/ZooDirector.app" "$work_dir/dmg-content/ZooDirector.app"
    ln -s /Applications "$work_dir/dmg-content/Applications"
    hdiutil create -volname ZooDirector -srcfolder "$work_dir/dmg-content" \
        -format UDZO -fs HFS+ "$image"
    codesign --force --timestamp --sign "$signing_identity" "$image"
    codesign --verify --strict --verbose=2 "$image"
    notarize_archive "$image" dmg
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    codesign --verify --strict --verbose=2 "$image"
    hdiutil verify "$image"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
}

# 仅在全部检查成功后替换正式产物；通用应用替换失败时恢复旧版本。
package_release() {
    local version output_file
    version="$(plutil -extract ZooDirectorDisplayVersion raw -o - "$work_dir/ZooDirector.app/Contents/Info.plist")"
    if [[ "$target_arch" == universal ]]; then
        output_file="$PWD/dist/ZooDirector-${version}-universal.app"
        if [[ -e "$output_file" ]]; then
            mv "$output_file" "$work_dir/previous.app"
        fi
        if ! mv "$work_dir/ZooDirector.app" "$output_file"; then
            if [[ -d "$work_dir/previous.app" ]]; then
                mv "$work_dir/previous.app" "$output_file"
            fi
            return 1
        fi
    else
        create_dmg
        output_file="$PWD/dist/ZooDirector-${version}-${target_arch}.dmg"
        mv -f "$work_dir/distribution.dmg" "$output_file"
    fi
    printf '正式分发产物：%s\n' "$output_file"
    printf '公证记录及工作文件：%s\n' "$work_dir"
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    show_help
    exit 0
fi
# 校验所有架构参数后再访问钥匙串，防止参数错误时开始发布。
architectures=("$@")
if (( $# == 0 )); then
    architectures=(arm64 x86_64 universal)
fi
for target_arch in "${architectures[@]}"; do
    if [[ "$target_arch" != arm64 && "$target_arch" != x86_64 && "$target_arch" != universal ]]; then
        show_help >&2
        exit 1
    fi
done
trap report_exit EXIT
export DISTRIBUTION_CHANNEL="${DISTRIBUTION_CHANNEL:-github}"
python3 scripts/build-metadata.py --validate-only
if [[ "$DISTRIBUTION_CHANNEL" != github ]]; then
    printf '此脚本仅用于 GitHub / Developer ID 分发；App Store 发布流程尚未实现。\n' >&2
    exit 1
fi
check_requirements
mkdir -p dist
for target_arch in "${architectures[@]}"; do
    printf '\n开始发布架构：%s\n' "$target_arch"
    work_dir="$(mktemp -d "$PWD/dist/.release.${target_arch}.XXXXXX")"
    build_and_sign
    notarize_app
    package_release
done
