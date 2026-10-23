#!/usr/bin/env bash
# fqapp macOS 构建入口（Intel x86_64，可运行于 macOS 13 Ventura）。
#
# 上游没有 macos/ 目录：本脚本首次运行时用 `flutter create --platforms=macos`
# 生成平台壳，然后覆盖两份 entitlements。上游模板默认开启 App Sandbox，而本
# 移植需要 dlopen 随包 dylib、在回环地址起本地服务、spawn caffeinate 保持唤醒，
# 沙盒会把这三件事全部拦掉，所以这里显式关掉沙盒、关闭库校验。
#
# 用法：
#   scripts/build_macos.sh                  # 完整构建 + 校验 + 打 zip
#   FQAPP_MACOS_CODEGEN=1 scripts/build_macos.sh   # 先重跑 FRB codegen
#   FQAPP_MACOS_SKIP_PACKAGE=1 scripts/build_macos.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT_NAME="fqapp"
CORE_DYLIB="rust/target/release/libfqapi_core.dylib"
APP="build/macos/Build/Products/Release/${PROJECT_NAME}.app"
ZIP="fqapp-macos-x64.zip"

die() { echo "错误：$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "本脚本只能在 macOS 上运行。"
command -v flutter >/dev/null 2>&1 || die "未找到 flutter。"
command -v cargo >/dev/null 2>&1 || die "未找到 cargo。"

echo "==> 1/6 生成 macos/ 平台壳（上游缺这个目录）"
if [ ! -d macos ]; then
  flutter create --platforms=macos --project-name "$PROJECT_NAME" --org com.fqapp .
fi
[ -f macos/Runner/Release.entitlements ] ||
  die "macos/ 生成异常：缺少 Runner/Release.entitlements"

echo "==> 2/6 覆盖 entitlements（关沙盒、允许加载随包 dylib）"
cat > macos/Runner/Release.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- 自用移植：不用 App Sandbox。沙盒下 dlopen 随包 dylib、回环监听、
	     spawn caffeinate 都需要额外授权，收益不抵成本。 -->
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<!-- flutter build macos 用 ad-hoc 签名，需允许加载非同一 TeamID 的 dylib。 -->
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
</dict>
</plist>
PLIST

cat > macos/Runner/DebugProfile.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
	<!-- Debug 下 Dart VM 走 JIT。 -->
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> 2b/6 用与 Android 同源的图标替换 AppIcon"
# flutter create 生成的是 Flutter 默认图标；Android 那边由
# scripts/generate_app_icons.py 从 assets/branding/app_icon_source.png 生成，
# 这里用同一份源图导出的 1024px master 切成 AppIcon.appiconset 的 10 个槽位，
# 两个平台才会看起来是同一个应用。尺寸清单见 assets/branding/macos/Contents.json。
ICON_MASTER="assets/branding/app_icon_macos.png"
ICONSET="macos/Runner/Assets.xcassets/AppIcon.appiconset"
[ -s "$ICON_MASTER" ] || die "缺少 $ICON_MASTER（先跑 python scripts/generate_app_icons.py）"
[ -f assets/branding/macos/Contents.json ] || die "缺少 assets/branding/macos/Contents.json"
[ -d macos/Runner/Assets.xcassets ] || die "macos/ 生成异常：缺少 Assets.xcassets"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp assets/branding/macos/Contents.json "$ICONSET/Contents.json"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
            128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
            512:512x512 1024:512x512@2x; do
  px="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$px" "$px" "$ICON_MASTER" --out "$ICONSET/icon_${name}.png" >/dev/null
done
echo "    AppIcon.appiconset 已生成 10 个尺寸（16 → 512@2x）"

# --- macOS 专用的依赖覆盖 ---------------------------------------------------
# macOS 构建机只有 Xcode 16.4（macOS 15.5 SDK），connectivity_plus 7.1.0+ 用到的
# NWPath.isUltraConstrained 编译不过；Android 侧继续用 7.3.x。这里用 pub 官方的
# pubspec_overrides.yaml 做局部覆盖，pubspec.yaml / pubspec.lock 保持 Android 取值。
# 覆盖文件与 lock 只在本次构建期间变化，脚本退出（含失败）时一律还原 ——
# Android 的 CI 带 --enforce-lockfile，留着 7.0.0 的 lock 会直接把那次构建打红。
OVERRIDES_FILE="pubspec_overrides.yaml"
LOCK_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/fqapp-lock.XXXXXX")"
cp pubspec.lock "$LOCK_SNAPSHOT"
PREV_OVERRIDES=""
if [ -f "$OVERRIDES_FILE" ]; then
  PREV_OVERRIDES="$(mktemp "${TMPDIR:-/tmp}/fqapp-overrides.XXXXXX")"
  mv "$OVERRIDES_FILE" "$PREV_OVERRIDES"
fi
restore_android_deps() {
  rm -f "$OVERRIDES_FILE"
  if [ -n "$PREV_OVERRIDES" ]; then mv "$PREV_OVERRIDES" "$OVERRIDES_FILE"; fi
  cp "$LOCK_SNAPSHOT" pubspec.lock
  rm -f "$LOCK_SNAPSHOT"
  echo "==> 已还原 pubspec.lock（Android 依赖回到 7.3.x）"
}
trap restore_android_deps EXIT

if [ "${FQAPP_MACOS_CODEGEN:-0}" = "1" ]; then
  echo "==> 2c/6 重跑 flutter_rust_bridge codegen"
  if ! command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
  fi
  flutter_rust_bridge_codegen generate --config-file flutter_rust_bridge.yaml
fi

echo "==> 2d/6 生成 pubspec_overrides.yaml（connectivity_plus → 7.0.0，仅本次 macOS 构建）"
cat > "$OVERRIDES_FILE" <<'YAML'
dependency_overrides:
  connectivity_plus: 7.0.0
YAML

echo "==> 3/6 flutter pub get"
flutter pub get

echo "==> 4/6 编译 Rust 核心（host target = 当前架构）"
cargo build --release --manifest-path rust/Cargo.toml
[ -s "$CORE_DYLIB" ] || die "Rust 未产出 $CORE_DYLIB"

echo "==> 5/6 flutter build macos --release"
flutter build macos --release --no-pub
[ -d "$APP" ] || die "未产出 $APP"

# FRB 在 macOS 上的兜底是裸名 dlopen("libfqapi_core.dylib")，不会搜索 .app 包内，
# 所以核心必须放进 Contents/MacOS，并由 backend_transport 显式给绝对路径。
cp -f "$CORE_DYLIB" "$APP/Contents/MacOS/libfqapi_core.dylib"
codesign --force --sign - "$APP/Contents/MacOS/libfqapi_core.dylib"
codesign --force --deep --sign - "$APP"

echo "==> 6/6 校验架构与最低系统版本"
BIN="$APP/Contents/MacOS/$PROJECT_NAME"
[ -f "$BIN" ] || die "找不到可执行文件 $BIN"

assert_arch() {
  local file="$1" want="$2" got
  got="$(lipo -archs "$file")"
  case " $got " in
    *" $want "*) echo "    $(basename "$file") → $got" ;;
    *) die "$file 架构为「${got}」，缺少 $want" ;;
  esac
}

# 宿主机是 x86_64 runner 时，Flutter 原生产出 x86_64；若在 Apple Silicon 上跑，
# 这里会直接失败，提示改用 x86_64 构建（见 PORTING-MACOS.md）。
assert_arch "$BIN" "x86_64"
assert_arch "$APP/Contents/MacOS/libfqapi_core.dylib" "x86_64"

min_os() {
  otool -l "$1" |
    awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/ {found=1}
         found && /minos|version/ {print $2; exit}'
}
MINOS="$(min_os "$BIN")"
[ -n "$MINOS" ] || die "读不出 $BIN 的最低系统版本"
# Ventura = 13.0；比它高就意味着 Intel Ventura 跑不了。
if ! awk -v m="$MINOS" 'BEGIN {
      split(m, a, "."); major = a[1] + 0;
      exit !(major <= 13)
    }'; then
  die "最低系统版本 $MINOS 高于 macOS 13 Ventura"
fi
# 必须用 ${MINOS} 大括号：紧跟全角括号时，bash 在 UTF-8 locale 下会把
# 「（」的首字节当成变量名的一部分，set -u 于是报 "MINOS?: unbound variable"。
echo "    最低系统版本 → ${MINOS}（≤ 13 即 Ventura 可用）"

# 版本号必须和 Android 同源（pubspec.yaml 的 version）：Release 里两个包共用
# 同一个 tag，版本对不上就说明装错了包，或者 Flutter 没读到 pubspec。
PUB_VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
case "$PUB_VERSION" in
  *+*) WANT_NAME="${PUB_VERSION%%+*}"; WANT_BUILD="${PUB_VERSION##*+}" ;;
  *)   WANT_NAME="$PUB_VERSION"; WANT_BUILD="$PUB_VERSION" ;;
esac
[ -n "$WANT_NAME" ] || die "pubspec.yaml 里读不出 version"
PLIST="$APP/Contents/Info.plist"
GOT_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)"
GOT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null)"
[ "$GOT_NAME" = "$WANT_NAME" ] ||
  die "CFBundleShortVersionString=${GOT_NAME}，与 pubspec 的 ${WANT_NAME} 不一致"
[ "$GOT_BUILD" = "$WANT_BUILD" ] ||
  die "CFBundleVersion=${GOT_BUILD}，与 pubspec 的 build ${WANT_BUILD} 不一致"
echo "    版本 → ${GOT_NAME} (${GOT_BUILD})，与 Android 同源"

if [ "${FQAPP_MACOS_SKIP_PACKAGE:-0}" != "1" ]; then
  rm -f "$ZIP"
  # ditto 才能保住 .app 里的符号链接（含 Frameworks），zip -r 会破坏签名。
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "==> 产物：$ZIP"
  shasum -a 256 "$ZIP"
fi

echo "==> 完成"
