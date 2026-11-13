#!/usr/bin/env bash
# fqapp macOS 构建入口（默认出 universal 包：arm64 + x86_64 合在一个 .app 里）。
#
# 上游没有 macos/ 目录：本脚本首次运行时用 `flutter create --platforms=macos`
# 生成平台壳，然后覆盖两份 entitlements。上游模板默认开启 App Sandbox，而本
# 移植需要 dlopen 随包 dylib、在回环地址起本地服务、spawn caffeinate 保持唤醒，
# 沙盒会把这三件事全部拦掉，所以这里显式关掉沙盒、关闭库校验。
#
# 用法：
#   scripts/build_macos.sh                          # 完整构建（universal）+ 校验 + 打 zip
#   FQAPP_MACOS_ARCH=arm64 scripts/build_macos.sh   # 只出单架构（排障 / 省时间用）
#   FQAPP_MACOS_CODEGEN=1 scripts/build_macos.sh    # 先重跑 FRB codegen
#   FQAPP_MACOS_SKIP_PACKAGE=1 scripts/build_macos.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT_NAME="fqapp"

die() { echo "错误：$*" >&2; exit 1; }

# --- 目标架构 ---------------------------------------------------------------
# 默认出 universal（arm64 + x86_64 同在一个 .app 内）：用户不用挑包，Intel 与
# Apple Silicon 装同一个 zip 都能跑。两份 slice 只在磁盘上共存，运行时 dyld 只
# 映射当前架构那一份（实测 universal 与 thin 的物理内存、启动耗时一致），所以
# 「合一」的代价只有下载量与占盘，没有运行开销。
#
# arm64 与 x86_64 共用同一份源码，差异只有三处：Rust target triple、Xcode 的
# ARCHS、产物名。Dart 侧不需要改：全仓库都用 Platform.isMacOS 判断平台。
HOST_ARCH="$(uname -m)"
TARGET_ARCH="${FQAPP_MACOS_ARCH:-universal}"
case "$TARGET_ARCH" in
  universal)
    # universal 走 `flutter build macos` 的默认路径（Xcode ARCHS_STANDARD 在
    # macOS 上就是 arm64 + x86_64）；那条路径只在 Apple Silicon 宿主上验证过，
    # 在 Intel 宿主上会因 ARCHS_STANDARD 退化成单架构，所以这里直接挡住。
    [ "$HOST_ARCH" = "arm64" ] ||
      die "universal 包只能在 Apple Silicon 上构建（当前宿主 ${HOST_ARCH}）；要交叉出包请显式传 FQAPP_MACOS_ARCH=arm64 / x86_64"
    RUST_TRIPLES=(aarch64-apple-darwin x86_64-apple-darwin)
    PKG_SUFFIX=""
    ;;
  arm64)
    RUST_TRIPLES=(aarch64-apple-darwin)
    PKG_SUFFIX="-arm64"
    ;;
  x86_64)
    RUST_TRIPLES=(x86_64-apple-darwin)
    PKG_SUFFIX="-x64"
    ;;
  *)
    die "不支持的架构「${TARGET_ARCH}」，只支持 universal / arm64 / x86_64"
    ;;
esac

APP="build/macos/Build/Products/Release/${PROJECT_NAME}.app"
ZIP="fqapp-macos${PKG_SUFFIX}.zip"

# 最低系统版本（单一可调点）。取 13.0 = Ventura：
#   - 技术下限：arm64 要求 ≥ 11.0，低于这个 Xcode 直接报
#     「range of supported deployment target versions is 11.0 to ...」；
#   - 实际基线：本项目对外一直写「macOS 13 Ventura 可用」，Release 说明里也是
#     「桌面版只有 macOS 13+」，取 13.0 让构建产物和这句话对齐；
#   - 代价：Big Sur(11) / Monterey(12) 不再支持。要让老机器也能跑就改回 11.0，
#     其余逻辑不用动。
DEPLOY_MIN="13.0"
DEPLOY_MAJOR="${DEPLOY_MIN%%.*}"

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
# 原始起因：macOS 构建机是 Xcode 16.4（macOS 15.5 SDK），connectivity_plus 7.1.0+
# 用到的 NWPath.isUltraConstrained 编译不过；Android 侧继续用 7.3.x。这里用 pub
# 官方的 pubspec_overrides.yaml 做局部覆盖，pubspec.yaml / pubspec.lock 保持
# Android 取值。
# 现在 CI 已换 macos-26（Xcode 26 / macOS 26 SDK），这条覆盖理论上不再必要，
# 但换镜像的当次只动一个变量，等新镜像稳定出包后再单独去掉。
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

echo "==> 2e/6 抬最低系统版本到 ${DEPLOY_MIN}（Ventura 基线）"
# `flutter create` 生成的模板是 10.14，低于 arm64 的硬下限 11.0，也低于本项目
# 对外宣称的 13；Xcode 对 arm64 会直接报「range of supported deployment target
# versions is 11.0 to ...」。这里只抬不降 —— 匹配 0–12 的主版本号，已经 ≥ 13 的
# 一律不动（模板哪天变成 14 也不会被这个脚本降回去）。
/usr/bin/sed -i '' -E \
  "s/^platform :osx, *'([0-9]|1[0-2])\.[0-9]+'/platform :osx, '${DEPLOY_MIN}'/" \
  macos/Podfile
/usr/bin/sed -i '' -E \
  "s/MACOSX_DEPLOYMENT_TARGET = ([0-9]|1[0-2])\.[0-9]+;/MACOSX_DEPLOYMENT_TARGET = ${DEPLOY_MIN};/g" \
  macos/Runner.xcodeproj/project.pbxproj

POD_PLATFORM="$(/usr/bin/sed -n -E "s/^platform :osx, *'([0-9.]+)'.*/\1/p" macos/Podfile | head -1)"
[ -n "$POD_PLATFORM" ] ||
  die "macos/Podfile 里读不出 platform :osx（模板结构变了？）"
awk -v p="$POD_PLATFORM" -v want="$DEPLOY_MAJOR" 'BEGIN {
      split(p, a, "."); exit !(a[1] + 0 >= want + 0)
    }' ||
  die "macos/Podfile 的 platform :osx 仍是 ${POD_PLATFORM}，低于 ${DEPLOY_MIN}"
echo "    Podfile platform :osx → ${POD_PLATFORM}"

echo "==> 2f/6 关掉 Impeller（macOS 桌面用回 Skia）"
# Flutter 3.47 起把 macOS 桌面的默认渲染器从 Skia 换成了 Impeller（Metal），
# 而 media_kit 在 macOS 上的视频输出是「mpv OpenGL → CVPixelBuffer → Flutter
# texture」的零拷贝路径。换到 Impeller 之后这条链路在 Intel Mac 上是花屏 +
# 掉帧；再叠加 `vo=libmpv` 以音频为主时钟、视频落后不自动追平，就成了越播越
# 不同步。v1.0.200-fq2（Flutter 3.44，默认 Skia）正常、fq3 起异常，原因只在
# 渲染器这一层。
#
# 官方留的回退开关就是下面这个 Info.plist 键。注意它是整包生效的：universal
# 包里没有「arm64 用 Impeller、x86_64 用 Skia」这种可能，要么都开、要么都关。
# 回退选项将来会被移除，届时只能换掉 media_kit 的纹理实现（等上游支持 Impeller）。
PLIST="macos/Runner/Info.plist"
[ -f "$PLIST" ] || die "macos/ 生成异常：缺少 Runner/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :FLTEnableImpeller" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :FLTEnableImpeller bool false" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :FLTEnableImpeller" "$PLIST" | grep -qx false ||
  die "Info.plist 里没写进 FLTEnableImpeller=false"
echo "    Info.plist FLTEnableImpeller → false"

echo "==> 3/6 flutter pub get"
flutter pub get

echo "==> 4/6 编译 Rust 核心（${RUST_TRIPLES[*]}）"
# 一律显式 --target，产物固定落在 rust/target/<triple>/release，避免宿主默认
# target 目录和交叉编译目录互相串味。universal 时两条都编，再 lipo 合成一份
# ——注意这里是唯一需要手工合并的地方：Flutter 的 Runner / App.framework 与
# Pods 的 framework 在 macOS 上本来就按 ARCHS_STANDARD 出双架构，只有 Rust
# 核心是按单一 triple 产的（历史产物里 dylib 就是 arm64-only，Intel 上会在
# dlopen 阶段挂掉）。
DYLIB_REL="release/libfqapi_core.dylib"
for triple in "${RUST_TRIPLES[@]}"; do
  cargo build --release --manifest-path rust/Cargo.toml --target "$triple"
  [ -s "rust/target/$triple/$DYLIB_REL" ] ||
    die "Rust 未产出 rust/target/$triple/$DYLIB_REL"
done
if [ "${#RUST_TRIPLES[@]}" -eq 1 ]; then
  CORE_DYLIB="rust/target/${RUST_TRIPLES[0]}/$DYLIB_REL"
else
  CORE_DYLIB="rust/target/universal/$DYLIB_REL"
  mkdir -p "$(dirname "$CORE_DYLIB")"
  slices=()
  for triple in "${RUST_TRIPLES[@]}"; do
    slices+=("rust/target/$triple/$DYLIB_REL")
  done
  lipo -create "${slices[@]}" -output "$CORE_DYLIB"
  echo "    lipo -create → $(lipo -archs "$CORE_DYLIB")"
fi

echo "==> 5/6 flutter build macos --release（ARCHS=${TARGET_ARCH}）"
if [ "$TARGET_ARCH" = "universal" ] || [ "$TARGET_ARCH" = "$HOST_ARCH" ]; then
  # 宿主与目标同架构（或要 universal）：走 Flutter 默认路径。macOS 工程的
  # Release.xcconfig 是 ARCHS_STANDARD，在 Apple Silicon 上就等于 arm64 +
  # x86_64 —— universal 正是靠这一点，再由下面 6/6 的严格校验兜底：万一哪天
  # ARCHS_STANDARD 退化成单架构，构建会当场失败，而不是悄悄发出一个 Intel 上
  # 起不来的包。
  flutter build macos --release --no-pub
else
  # 宿主 ≠ 目标（例如在 Apple Silicon 上要 x86_64）：`flutter build macos` 没有
  # 架构开关，只会出宿主架构。先 --config-only 生成 xcconfig 与 pod 集成，再用
  # xcodebuild 显式指定 ARCHS。产物仍落在 build/macos/Build/Products/Release。
  flutter build macos --release --no-pub --config-only
  xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
    -configuration Release \
    ARCHS="$TARGET_ARCH" ONLY_ACTIVE_ARCH=NO \
    build
fi
[ -d "$APP" ] || die "未产出 $APP"

# FRB 在 macOS 上的兜底是裸名 dlopen("libfqapi_core.dylib")，不会搜索 .app 包内，
# 所以核心必须放进 Contents/MacOS，并由 backend_transport 显式给绝对路径。
cp -f "$CORE_DYLIB" "$APP/Contents/MacOS/libfqapi_core.dylib"
codesign --force --sign - "$APP/Contents/MacOS/libfqapi_core.dylib"
codesign --force --deep --sign - "$APP"

echo "==> 6/6 校验架构与最低系统版本"
BIN="$APP/Contents/MacOS/$PROJECT_NAME"
[ -f "$BIN" ] || die "找不到可执行文件 $BIN"

# 新版 macOS 的 lipo 会把 arm64e / arm64e.x1 报成独立架构（系统二进制就是这样，
# 已经没有裸 arm64 的 slice）。它们都属于 arm64 家族、能在 Apple Silicon 上跑，
# 比对前统一折叠成 arm64，免得在 arm64 包上误报「缺少 slice」。
archs_norm() {
  printf '%s\n' "$1" |
    tr ' ' '\n' |
    /usr/bin/sed -E 's/^arm64e(\.[A-Za-z0-9_]+)?$/arm64/' |
    tr '\n' ' ' |
    /usr/bin/sed -E 's/ +$//'
}

# 目标架构集：universal 要求两条 slice 都在；单架构只要求含目标那一条（不禁止
# 超集 —— x64 包里的 framework 历史上本来就是 universal，多一份 slice 无害）。
# 注意 universal 的判断必须是「都在」而不是「含其一」：旧版脚本按「包含即通过」
# 校验 arm64 包，结果 dylib 单片、Intel 上 dlopen 才暴露，构建期一句警告都没有。
case "$TARGET_ARCH" in
  universal) WANT_ARCHS="arm64 x86_64" ;;
  *)         WANT_ARCHS="$TARGET_ARCH" ;;
esac

missing_archs() {
  local got="$1" miss="" w
  shift
  for w in "$@"; do
    case " $got " in
      *" $w "*) ;;
      *) miss="$miss $w" ;;
    esac
  done
  printf '%s' "$miss"
}

assert_arch() {
  local file="$1" got miss
  got="$(archs_norm "$(lipo -archs "$file")")"
  miss="$(missing_archs "$got" $WANT_ARCHS)"
  [ -z "$miss" ] || die "$file 架构为「${got}」，缺少${miss}"
  echo "    $(basename "$file") → $got"
}

# 主可执行文件与 Rust 核心的架构必须与目标一致。宿主与目标不同架构时最容易在
# 这里露馅（Flutter 会静默按宿主出包）。
assert_arch "$BIN"
assert_arch "$APP/Contents/MacOS/libfqapi_core.dylib"

# 再扫一遍包内的二进制目录：第三方预编译产物（libmpv 等）如果缺目标 slice，症状
# 是运行到播放页才崩，构建期先抓出来更省事。只看 Contents/MacOS 与
# Contents/Frameworks —— flutter_assets 里上万个资源文件不是 Mach-O，
# 对整个 .app 逐个 `file` 只是白等。
assert_arch_tree() {
  local root="$1" bad=0 f archs miss
  [ -d "$root" ] || return 0
  while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null)" in
      *Mach-O*) ;;
      *) continue ;;
    esac
    archs="$(archs_norm "$(lipo -archs "$f" 2>/dev/null || true)")"
    miss="$(missing_archs "$archs" $WANT_ARCHS)"
    if [ -n "$miss" ]; then
      echo "    缺少${miss}：${f#"$APP"/}（${archs:-未知}）" >&2
      bad=1
    fi
  done < <(find "$root" -type f)
  [ "$bad" -eq 0 ] || die "包内存在缺少 ${WANT_ARCHS} slice 的 Mach-O"
}
assert_arch_tree "$APP/Contents/MacOS"
assert_arch_tree "$APP/Contents/Frameworks"
echo "    包内全部 Mach-O 均含 ${WANT_ARCHS}"

# 渲染器回退要落在最终 .app 里：2f 步改的是模板，这条防的是「构建过程用自己的
# 模板把 Info.plist 覆盖掉」——那样包能装能开，视频照旧花屏。
/usr/libexec/PlistBuddy -c "Print :FLTEnableImpeller" \
  "$APP/Contents/Info.plist" 2>/dev/null | grep -qx false ||
  die "最终 .app 的 Info.plist 里没有 FLTEnableImpeller=false（渲染器仍是 Impeller）"
echo "    渲染器 → Skia（Impeller 已关闭）"

# universal 二进制会有两条 slice，必须逐条打印：只看第一条的话，第二条悄悄按
# 更高 SDK 编也查不出来（Intel 用户会在 Ventura 上加载失败）。
min_os() {
  otool -l "$1" |
    awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/ {found=1; next}
         found && /minos|version/ {print $2; found=0}'
}
# 主可执行文件每条 slice 的 minos 都必须正好等于基线：低了说明 2e 步的改写没
# 生效（模板结构变了或 sed 没匹配上），高了说明某个 pod 把下限顶起来了 ——
# 两种情况 Ventura 都不对。
MINOS_LIST="$(min_os "$BIN")"
[ -n "$MINOS_LIST" ] || die "读不出 $BIN 的最低系统版本"
BAD_MINOS=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  awk -v m="$m" -v want="$DEPLOY_MAJOR" 'BEGIN {
        split(m, a, ".");
        exit !(a[1] + 0 == want + 0)
      }' || BAD_MINOS="${BAD_MINOS} ${m}"
done <<< "$MINOS_LIST"
[ -z "$BAD_MINOS" ] ||
  die "最低系统版本${BAD_MINOS} 与基线 ${DEPLOY_MIN} 不一致（高于基线则 Ventura 跑不了，低于基线说明 2e 步没生效）"
# 必须用 ${...} 大括号：紧跟全角括号时，bash 在 UTF-8 locale 下会把「（」的
# 首字节当成变量名的一部分，set -u 于是报 "VAR?: unbound variable"。
echo "    最低系统版本 → ${MINOS_LIST//$'\n'/+}（基线 ${DEPLOY_MIN}，Ventura 可用）"

# 随包 framework / dylib 各自带着自己的 minos。主可执行文件是 13.0 不代表
# libmpv 之类也是 —— 某个 pod 若悄悄按 Sonoma 编，Ventura 上会在 dlopen 阶段
# 直接失败，而且只在用户机器上才暴露。这里逐个核对上界。
assert_minos_tree() {
  local root="$1" bad=0 f m
  [ -d "$root" ] || return 0
  while IFS= read -r f; do
    case "$(file -b "$f" 2>/dev/null)" in
      *Mach-O*) ;;
      *) continue ;;
    esac
    m="$(min_os "$f")"
    [ -n "$m" ] || continue
    # 逐条 slice 判断（universal 下每条 framework 也有两行）。awk 用退出码
    # 表达「超标」：> 基线时退 1，配合下面的 || 分支记为失败。注意不要写成
    # exit !(...) —— 那样正好反过来，正常库会被判成超标。
    while IFS= read -r one; do
      [ -n "$one" ] || continue
      awk -v m="$one" -v want="$DEPLOY_MAJOR" 'BEGIN {
            split(m, a, ".");
            exit (a[1] + 0 > want + 0)
          }' || {
        echo "    minos ${one} 高于基线 ${DEPLOY_MIN}：${f#"$APP"/}" >&2
        bad=1
      }
    done <<< "$m"
  done < <(find "$root" -type f)
  [ "$bad" -eq 0 ] ||
    die "包内存在最低系统版本高于 ${DEPLOY_MIN} 的 Mach-O，Ventura 上会加载失败"
}
assert_minos_tree "$APP/Contents/Frameworks"
echo "    包内 framework 的 minos 均不高于 ${DEPLOY_MIN}"

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
