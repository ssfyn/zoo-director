#!/bin/zsh
# 构建应用包；首个参数为构建配置，第二个可选参数指定目标架构。
set -euo pipefail
cd "$(dirname "$0")/.."
# 加载本机配置并导出变量，供当前脚本及其启动的子进程使用。
if [[ -f scripts/.env ]]; then
    set -a
    source scripts/.env
    set +a
fi
configuration="${1:-release}"
target_arch="${2:-}"
if (( $# > 2 )) || [[ "$configuration" != release && "$configuration" != debug ]] ||
   [[ -n "$target_arch" && "$target_arch" != arm64 && "$target_arch" != x86_64 && "$target_arch" != universal ]]; then
    printf '用法：%s [release|debug] [arm64|x86_64|universal]\n' "$0" >&2
    exit 1
fi

# 合并两个架构的主程序；资源必须完全一致，合并完成后重新生成临时签名。
build_universal() {
    local arm_app="$PWD/.build/apps/arm64/ZooDirector.app"
    local intel_app="$PWD/.build/apps/x86_64/ZooDirector.app"
    local universal_app="$PWD/.build/apps/universal/ZooDirector.app"
    local merge_dir
    ./scripts/build-app.sh "$configuration" arm64
    ./scripts/build-app.sh "$configuration" x86_64
    diff -rq "$arm_app/Contents/Resources" "$intel_app/Contents/Resources"
    cmp "$arm_app/Contents/Info.plist" "$intel_app/Contents/Info.plist"
    mkdir -p "$PWD/.build/apps/universal"
    merge_dir="$(mktemp -d "$PWD/.build/apps/universal/.merge.XXXXXX")"
    ditto "$arm_app" "$merge_dir/ZooDirector.app"
    lipo -create "$arm_app/Contents/MacOS/ZooDirector" \
        "$intel_app/Contents/MacOS/ZooDirector" \
        -output "$merge_dir/ZooDirector.app/Contents/MacOS/ZooDirector"
    codesign --force --sign - "$merge_dir/ZooDirector.app"
    codesign --verify --deep --strict "$merge_dir/ZooDirector.app"
    # 旧产物仅在合并与签名成功后替换，失败时保留临时目录用于诊断。
    if [[ -d "$universal_app" ]]; then
        mv "$universal_app" "$merge_dir/previous.app"
    fi
    if ! mv "$merge_dir/ZooDirector.app" "$universal_app"; then
        if [[ -d "$merge_dir/previous.app" ]]; then
            mv "$merge_dir/previous.app" "$universal_app"
        fi
        return 1
    fi
    rm -rf "$merge_dir"
    printf '通用应用已构建：%s\n' "$universal_app"
}

if [[ "$target_arch" == universal ]]; then
    build_universal
    exit 0
fi
build_args=(-c "$configuration" --disable-sandbox)
if [[ -n "$target_arch" ]]; then
    build_args+=(--arch "$target_arch")
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build "${build_args[@]}"
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"
app_dir="$PWD/.build/ZooDirector.app"
if [[ -n "$target_arch" ]]; then
    app_dir="$PWD/.build/apps/$target_arch/ZooDirector.app"
fi
# 首次去除名称中的空格时迁移已有应用，后续始终更新同一个应用包。
previous_app_dir="$PWD/.build/Zoo Director.app"
if [[ -z "$target_arch" && ! -e "$app_dir" && -d "$previous_app_dir" ]]; then
    mv "$previous_app_dir" "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$binary_dir/ZooDirector" "$app_dir/Contents/MacOS/ZooDirector"
cp Resources/ZooDirector.icns "$app_dir/Contents/Resources/ZooDirector.icns"
# 将语言目录随应用打包，确保脱离构建目录后仍能加载翻译。
cp -R "$binary_dir/ZooDirector_ZooDirector.bundle" "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ZooDirector</string>
<key>CFBundleIdentifier</key><string>fan.yanan.zoodirector</string>
<key>CFBundleName</key><string>ZooDirector</string>
<key>CFBundleDisplayName</key><string>ZooDirector</string>
<key>CFBundleIconFile</key><string>ZooDirector.icns</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
# 更新应用包时间并重新注册，让访达重新读取原地构建后的图标资源。
touch "$app_dir"
if [[ -z "$target_arch" ]] && ! /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_dir"; then
    printf '应用已构建，但系统应用注册未刷新；可在退出应用后重新打开。\n' >&2
fi
printf '应用已构建：%s\n' "$app_dir"
