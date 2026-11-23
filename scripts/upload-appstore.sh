#!/bin/zsh
# 校验或上传现有商店安装包；默认只校验，上传不会提交审核。
set -euo pipefail
cd "$(dirname "$0")/.."
# 本机加载私有配置，持续集成使用调用方提供的变量。
if [[ "${GITHUB_ACTIONS:-false}" != true && -f scripts/.env ]]; then
    set -a
    source scripts/.env
    set +a
fi

# 显示认证与操作说明，不读取上传密码。
show_help() {
    cat <<'HELP'
用法：
  ./scripts/upload-appstore.sh dist/ZooDirector-1.0.0-1-appstore.pkg
  ./scripts/upload-appstore.sh --upload dist/ZooDirector-1.0.0-1-appstore.pkg
  ./scripts/upload-appstore.sh --transporter dist/ZooDirector-1.0.0-1-appstore.pkg

默认通过苹果服务校验安装包；--upload 先校验再上传，不提交审核。
--transporter 在 Transporter 中打开安装包，供用户登录和交付。

命令行认证：
  APPSTORE_APPLE_ID       开发者账号邮箱。
  APPSTORE_PASSWORD_ITEM  altool 钥匙串条目，默认 zoodirector-appstore。
  APPSTORE_PROVIDER_ID    多个提供商时可显式指定，通常可省略。

首次在终端保存 App 专用密码（不把密码写在命令或 .env 中）：
  xcrun altool --store-password-in-keychain-item zoodirector-appstore --username 你的邮箱
按提示输入密码。notarytool 的凭据名称不能直接用于 altool。
HELP
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    show_help
    exit 0
fi
mode=validate
if [[ "${1:-}" == --upload ]]; then
    mode=upload
    shift
elif [[ "${1:-}" == --transporter ]]; then
    mode=transporter
    shift
fi
if (( $# != 1 )) || [[ "$1" != *.pkg || ! -f "$1" ]]; then
    show_help >&2
    exit 1
fi
package="${1:A}"
pkgutil --check-signature "$package"
if [[ "$mode" == transporter ]]; then
    open -a Transporter "$package"
    exit 0
fi
if [[ -z "${APPSTORE_APPLE_ID:-}" ]]; then
    printf '请配置 APPSTORE_APPLE_ID，或使用 --transporter 在应用中登录上传。\n' >&2
    exit 1
fi
authentication=(--username "$APPSTORE_APPLE_ID" --password "@keychain:${APPSTORE_PASSWORD_ITEM:-zoodirector-appstore}")
if [[ -n "${APPSTORE_PROVIDER_ID:-}" ]]; then
    authentication+=(--provider-public-id "$APPSTORE_PROVIDER_ID")
fi
# 根据本机帮助判断命令格式，兼容新旧 Xcode 的上传工具。
help_text="$(xcrun altool --help 2>&1)"
if [[ "$help_text" == *'--upload-package'* ]]; then
    xcrun altool --validate-app "$package" "${authentication[@]}"
    if [[ "$mode" == upload ]]; then
        xcrun altool --upload-package "$package" "${authentication[@]}" --wait
    fi
else
    if [[ -n "${APPSTORE_PROVIDER_ID:-}" ]]; then
        printf '旧版 altool 不支持此提供商参数，请更新 Xcode 或使用 Transporter。\n' >&2
        exit 1
    fi
    xcrun altool --validate-app -f "$package" -t macos "${authentication[@]}"
    if [[ "$mode" == upload ]]; then
        xcrun altool --upload-app -f "$package" -t macos "${authentication[@]}"
    fi
fi
