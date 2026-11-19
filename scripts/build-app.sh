#!/bin/zsh
# 构建本机架构的应用包；可传入 debug 加快开发构建。
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-cache"
swift build -c "$configuration" --disable-sandbox
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox)"
app_dir="$PWD/.build/ZooDirector.app"
# 首次去除名称中的空格时迁移已有应用，后续始终更新同一个应用包。
previous_app_dir="$PWD/.build/Zoo Director.app"
if [[ ! -e "$app_dir" && -d "$previous_app_dir" ]]; then
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
if ! /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_dir"; then
    printf '应用已构建，但系统应用注册未刷新；可在退出应用后重新打开。\n' >&2
fi
printf '应用已构建：%s\n' "$app_dir"
