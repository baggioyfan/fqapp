# fqapp macOS 版（Apple Silicon arm64 / Intel x86_64）

基于上游同一份代码的 macOS 移植，保留 GPL-3.0 许可与原作者署名。上游只发布
Android 与 Windows 桌面版，`macos/` 平台目录不存在，本分支补齐了它。

## 目标与产物

两个架构各出一个独立包，共用同一份源码：

| 架构 | 运行平台 | 最低系统 | 产物 |
|---|---|---|---|
| **arm64** | Apple Silicon（M1 及以后）**原生** | macOS 13 Ventura | `fqapp-macos-arm64.zip` |
| **x86_64** | Intel **原生**；Apple Silicon 上经 Rosetta 也可跑 | macOS 13 Ventura | `fqapp-macos-x64.zip` |

- **基线是 13.0 Ventura**（`build_macos.sh` 里的 `DEPLOY_MIN`，单一可调点）。
  技术上 arm64 只要求 ≥ 11.0，取 13.0 是为了跟对外一直写的「macOS 13 Ventura
  可用」和 Release 说明里的「桌面版只有 macOS 13+」对齐 —— 产物和说明不再打架。
- 代价：**Big Sur(11) / Monterey(12) 不再支持**。Apple Silicon 侧无实际损失
  （M1/M2 全系都能升到 Ventura 以上）；Intel 侧会挡掉停在 Monterey 及更早的
  2013–2016 机型。要让这些老机器也能跑，把 `DEPLOY_MIN` 改回 `11.0` 即可，
  其余逻辑不用动（2e 步的「只抬不降」改写和 minos 断言都跟着这个变量走）。
- 产物是 `fqapp.app` 打的 zip，**未做公证**（notarization），首次打开需右键 →
  打开，或执行 `xattr -dr com.apple.quarantine /Applications/fqapp.app`。
- 图标：与 Android 同一份源（`assets/branding/app_icon_source.png`）。运行
  `python scripts/generate_app_icons.py` 导出 1024px 的 `app_icon_macos.png`，
  构建时由 `build_macos.sh` 用 `sips` 切成 `AppIcon.appiconset` 的 10 个尺寸。
- 版本号：`CFBundleShortVersionString` / `CFBundleVersion` 来自 `pubspec.yaml`
  的 `version`，`build_macos.sh` 会断言它与 Android 一致（对不上就中止）。
- 发布：`android-apk.yml` 带 `release_tag` 的 dispatch 会以 `workflow_call`
  调起本工作流（`arch: both`），三个包（APK + 两个 .app）都成功后由它的
  `publish` job 建成**同一个 Release**。

## 怎么构建

### GitHub Actions（推荐，不需要本机装 Xcode）

- 工作流：`.github/workflows/macos.yml`
- 触发：Actions → `macOS build (Apple Silicon arm64 / Intel x86_64)` → Run
  workflow → **`arch` 选 `both` / `arm64` / `x86_64`**
- runner 分配：

  | 架构 | runner | 说明 |
  |---|---|---|
  | arm64 | `macos-15` | GitHub 标准 arm64（Apple Silicon）runner，GA |
  | x86_64 | `macos-15-intel` | 唯一的 x86_64 macOS runner，**2027-08 退役** |

  `macos-14` 已于 2026-11-02 退役，不要再用。`macos-26`（Xcode 26 / macOS 26
  SDK）已可用，但镜像较新，暂未切换。
- `pull_request` 触发时**只编 arm64**（新增路径 + 绝大多数用户会装的包），
  x64 由发布流程覆盖，避免每次 PR 都烧两倍 macOS runner 分钟。
- 产物在本次运行的 Artifacts 里（`fqapp-macos-arm64` / `fqapp-macos-x64`），
  保留 14 天。

### 本机构建

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked   # 仅改了 Rust API 层时需要
scripts/build_macos.sh                        # 跟随宿主架构
FQAPP_MACOS_ARCH=arm64 scripts/build_macos.sh # 指定 Apple Silicon
FQAPP_MACOS_ARCH=x86_64 scripts/build_macos.sh # 指定 Intel
```

脚本按 `$FQAPP_MACOS_ARCH`（缺省 = `uname -m`）选 Rust triple 与 Xcode `ARCHS`，
宿主与目标不同架构时自动走 `flutter build macos --config-only` + `xcodebuild
ARCHS=... ONLY_ACTIVE_ARCH=NO`，不用你手动敲那两行。

> ⚠️ 如果你的终端本身跑在 Rosetta 下（`sysctl -n sysctl.proc_translated` 返回
> 1），`uname -m` 会给出 `x86_64`，脚本就会安静地按 x86_64 出包。原生终端里
> 重跑，或显式传 `FQAPP_MACOS_ARCH=arm64`。

## arm64 与 x86_64 到底差在哪

Dart 业务层**零改动**：全仓库都用 `Platform.isMacOS` / `isMacHost` 判断平台，
没有任何架构分支。C 解密核心是纯 C11、无 SSE/AVX intrinsic，`native/` 下也没有
预编译产物，clang 直接给 arm64 编就行。差异全在构建层：

| 环节 | arm64 | x86_64 |
|---|---|---|
| Rust target | `aarch64-apple-darwin` | `x86_64-apple-darwin` |
| 核心库路径 | `rust/target/<triple>/release/libfqapi_core.dylib` | 同左 |
| `MACOSX_DEPLOYMENT_TARGET` | 13.0（基线一致） | 13.0（基线一致） |
| 产物名 | `fqapp-macos-arm64.zip` | `fqapp-macos-x64.zip` |

一律显式 `--target`，产物固定落在 `rust/target/<triple>/release`，不会和宿主
默认 target 目录串味。

## 相对上游改了什么

| 位置 | 改动 | 为什么 |
|---|---|---|
| `lib/services/desktop_platform.dart` | `isWindowsDesktop` → 新增 `isDesktopHost`（Windows∨macOS）与 `isMacDesktop` | 桌面分支（布局、播放、阅读器）两边共用，只有少数系统原语需要分叉 |
| 同上 | 防休眠：Windows 的 `SetThreadExecutionState` → macOS 起一个 `caffeinate -d -i` 子进程 | 阅读/听书/播放时不能息屏 |
| 同上 | GBK TXT 解码：`MultiByteToWideChar(54936)` → libiconv（`/usr/lib/libiconv.2.dylib`） | 非 UTF-8 的原文 TXT 需要 GB18030 解码，macOS 没有 Win32 那个 API |
| 同上 | 系统媒体键 SMTC 段用 `isWindowsDesktop` 包起来 | SMTC 是 Windows 专有；macOS 需要 `MPNowPlayingInfoCenter`，本版未做（媒体键无响应，其余不受影响） |
| 同上 | 语音设置深链 `explorer.exe ms-settings:speech` → `open x-apple.systempreferences:...` | 打开系统语音设置 |
| `lib/services/backend_transport.dart` | `RustLib.init()` 显式传 `externalLibrary` | flutter_rust_bridge 在 macOS 上兜底是裸名 `dlopen("libfqapi_core.dylib")`，**不会**搜索 .app 包内；Windows 能工作只是 DLL 搜索顺序凑巧 |
| `lib/services/desktop_media.dart` | `fqapi_core.dll` → `libfqapi_core.dylib` | FFI 解密代理的加载路径 |
| `rust/build.rs` | C 解密核心原来**只在 Windows** 编译，现在 macOS 也编 | 这些 C 文件是纯 C11/POSIX，macOS clang 可直接编（arm64 同样直接编） |
| `rust/Cargo.toml` | `reqwest` 的 `blocking` feature 从 `cfg(windows)` 扩到 `cfg(any(windows, macos))` | `desktop_media` 用阻塞客户端做本地回环代理 |
| `rust/src/lib.rs` | `mod desktop_media` 的 cfg 门加 macOS | 同上 |
| `pubspec.yaml` | 新增 `media_kit_libs_macos_video` | libmpv（上游只出 universal / arm64 两种，arm64 slice 齐全） |
| `pubspec_overrides.yaml`（构建期生成，不入库） | macOS 构建把 `connectivity_plus` 降到 `7.0.0`；`pubspec.yaml` / `pubspec.lock` 保持 Android 的 `^7.3.1` | 7.1.0 起用了 macOS 26 的 `NWPath.isUltraConstrained`，Xcode 16.4 编不过；本项目只用 `none/wifi/ethernet`，无 API 依赖 |
| `lib/services/secret_store.dart` | 新增系统钥匙串后端：通道不存在时（macOS/Windows runner 是 `flutter create` 原样输出，没有 `SecretStorePlugin`）改走 `flutter_secure_storage` | 原先桌面端 WebDAV 密码**根本存不下来** |
| `lib/services/secure_key_provider.dart` | `FlutterSecureStorage` 显式传 `MacOsOptions(useDataProtectionKeyChain: false)` | 插件默认走 data protection keychain，需要 `keychain-access-groups` 授权，ad-hoc 签名下 `SecItemAdd` 返回 `-34018`；拿不到 Hive 密钥等于每次启动都换钥匙，本地数据全成空库 |
| `assets/branding/app_icon_macos.png`<br>`assets/branding/macos/Contents.json` | 新增（由 `scripts/generate_app_icons.py` 从 Android 的同一份源图生成） | macOS 图标与 Android 同源，覆盖 `flutter create` 的默认 Flutter 图标 |
| `scripts/build_macos.sh` | 新增 | 生成 `macos/` 壳、换图标、覆盖 entitlements、**按目标架构选 Rust triple 与 Xcode ARCHS**、抬 `MACOSX_DEPLOYMENT_TARGET` 到 `DEPLOY_MIN`（13.0）、构建期降 `connectivity_plus`、编 Rust、打进 .app、签名、校验**架构 / 包内 Mach-O slice / `minos` / 版本号** |
| `.github/workflows/macos.yml` | 新增 | 先在 `plan` job 里算出架构矩阵，再在 `macos-15`（arm64）与 `macos-15-intel`（x86_64）上并行构建；暴露 `workflow_call` 供 `android-apk.yml` 发布时复用 |

`macos/` 目录本身没有提交——由构建脚本用 `flutter create --platforms=macos`
生成，避免手写 Xcode 工程。生成后脚本会覆盖两份 entitlements：关掉 App Sandbox，
打开 `disable-library-validation`（ad-hoc 签名下加载随包 dylib 需要）。

## 已知缺口

- **番茄书架导入不可用**：上游用 `webview_windows`（WebView2），macOS 需要
  WKWebView 实现。WebDAV 同步、JSON 备份/恢复不受影响。
- **系统媒体键/正在播放不显示**：见上表 SMTC 一行。
- **未做公证**：自用没问题，分发给别人会被 Gatekeeper 拦一次。
- **两个包不通用**：arm64 包在 Intel 机器上无法运行（反之 x64 包在 Apple
  Silicon 上要装 Rosetta）。想合并成一个 universal 包需要 Rust 双架构 `lipo`
  且所有 CocoaPods 依赖都能出双 slice，本版没做。
- **发布是原子的**：`android-apk.yml` 的 `publish` job 要求 APK 与**两个** macOS
  job 都成功才建 Release，所以任一架构构建失败时那一版 APK 也不会发布（只会
  留在 Artifacts 里 14 天）。两个 macOS job 并行，但 `macos-15` 只有 3 vCPU，
  整体时长仍以它为准。
- **构建产物的 Rust 桥接必须与已提交的 codegen 一致**：本次只动了 cfg 与
  非 `crate::api` 的模块，`rustContentHash` 不变，所以 CI 默认跳过 codegen。
  若启动即崩且报 content hash 不符，用 `run_codegen` 输入重跑一次。
- **`.github/release-notes.md` 是逐版手写的**：加 arm64 后要在下一次发版时
  补上 arm64 条目（`fqapp-<tag>-macos-arm64.zip`），否则 Release 页只说 Intel。

## 排错对照

| 症状 | 原因 | 处理 |
|---|---|---|
| 启动报 `libfqapi_core.dylib` 打不开 | 核心没进 `Contents/MacOS` | 检查 `build_macos.sh` 第 5 步；确认 `cargo build --release --target <triple>` 产出 |
| 启动崩、提示 content hash / codegen version | 桥接与 Rust 源码不一致 | Actions 里勾 `run_codegen` 重跑 |
| 视频页黑屏、只有声音 | libmpv 没进包，或缺目标架构 slice | 构建期 `assert_arch_tree` 会先拦下；没拦到就查 `pod install` 是否拉到 `media_kit_libs_macos_video` |
| 构建报 `range of supported deployment target versions is 11.0 to ...` | `MACOSX_DEPLOYMENT_TARGET` 低于 arm64 的硬下限 11.0（比基线 13.0 还低） | 脚本 2e 步会自动抬到 `DEPLOY_MIN`（13.0）；若 Podfile 被手改过，删掉 `macos/` 重新生成 |
| 构建报 `minos ... 与基线 13.0 不一致` | 产物 `minos` 不等于基线：高于基线说明某个 pod 把下限顶起来了，低于基线说明 2e 步没生效 | 先看 `pod install` 输出里哪个 pod 要求更高；确实需要更高就同步改 `DEPLOY_MIN` 并更新本文档的兼容性说明 |
| 产物架构不对（要 arm64 拿到 x86_64） | 宿主或终端在 Rosetta 下，`uname -m` 返回 `x86_64` | `sysctl -n sysctl.proc_translated` 查；显式 `FQAPP_MACOS_ARCH=arm64` |
| Apple Silicon 上提示要装 Rosetta | 装的是 x64 包 | 换 `fqapp-macos-arm64.zip` |
| arm64 包双击即退、无任何窗口 | 二进制没签名或签名被破坏（arm64 强制要求有效签名，ad-hoc 也算） | `codesign -dv --verbose=2 fqapp.app` 看 Sealed Resources；`codesign --force --deep --sign - fqapp.app` 重签 |
| `pod install` 报 platform 版本不够 | `macos/Podfile` 的 `platform :osx` 低于某个 pod 的下限 | 第 2e 步已统一到 13.0；仍不够就抬到该 pod 的下限并同步 `DEPLOY_MIN` |
| `flutter build macos` 报 Xcode/CLT 版本不匹配 | runner 镜像的 Xcode 被换过 | 固定 runner 镜像标签，必要时用 `sudo xcode-select -s` 指向合格版本 |
| 打开 app 提示「已损坏」 | 未公证 + quarantine | `xattr -dr com.apple.quarantine fqapp.app` |
| 阅读时不阻止息屏 | `caffeinate` 没起来 | 手动 `which caffeinate`，macOS 自带 |
| `flutter test` 里 `Failed to load dynamic library 'kernel32.dll'` | `flutter test` 会把 `defaultTargetPlatform` 强制成 **android**（FLUTTER_TEST 环境变量），基于 `TargetPlatform` 的 `isMacDesktop` 在测试宿主上恒为 false | 挑原生库/原生二进制一律用 `dart:io` 的 `Platform`（本分支已加 `isMacHost` / `isWindowsHost`），不要用 `defaultTargetPlatform` |
| `xcodebuild` 报某插件 `has no member 'isUltraConstrained'` | 插件用了 macOS 26 SDK 的新 Swift API，`#available` 只在运行时判断，编译期仍需符号存在；Xcode 16.4 只有 macOS 15.5 SDK | 构建期用 `pubspec_overrides.yaml` 把 `connectivity_plus` 降到 7.0.0（脚本与 CI 已自动生成并还原），或换带 macOS 26 SDK 的构建机 |
| Android job 报 `Unable to satisfy pubspec.yaml using pubspec.lock` | 改了 `pubspec.yaml` 的依赖但没同步 `pubspec.lock`（Android 的 CI 带 `--enforce-lockfile`） | 跑一次 `flutter pub get` 并提交 lock；无 Flutter 环境时可按 pub.dev API 的 `archive_sha256` 手改 |
| 日志显示 app 已 Built 但 job 仍失败 | 脚本收尾的 `echo "... ${VAR}（...）"` 用了 `$VAR` 紧贴全角字符，被 bash 当成变量名一部分，`set -u` 报 unbound variable | 变量一律写 `${VAR}` |
| WebDAV 保存密码提示「当前环境不支持系统密钥库」 | 桌面 runner 没有 `fqapp/secrets` 通道 | 已修：`SecretStore` 在通道缺失时改用系统钥匙串 |
| 钥匙串报 `-34018 A required entitlement is not present` | 用了 data protection keychain，而它要求 `keychain-access-groups` 授权；本构建是 ad-hoc 签名 | 已修：所有 `FlutterSecureStorage` 都显式 `MacOsOptions(useDataProtectionKeyChain: false)` |
| 首次打开后书架/历史是空的、重启又空 | 同上 `-34018`：Hive 密钥读不出来，每次启动生成新钥匙 | 同上，换传统 keychain 后密钥才会持久化。日志里搜 `secure-key` 可确认是否降级 |
| 每次启动都弹「fqapp 想使用钥匙串中的机密信息」 | ad-hoc 签名的 cdhash 每次构建都变，钥匙串 ACL 不认新二进制 | 点「始终允许」；自用可在钥匙串访问里把该项 ACL 永久放行 |
