# fqapp macOS 版（Intel x86_64 / Ventura 兼容）

基于上游同一份代码的 macOS 移植，保留 GPL-3.0 许可与原作者署名。上游只发布
Android 与 Windows 桌面版，`macos/` 平台目录不存在，本分支补齐了它。

## 目标与产物

- 架构：**x86_64（Intel）**
- 最低系统：不高于 **macOS 13 Ventura**（构建脚本会校验 `minos`，超了就报错）
- 产物：`fqapp-macos-x64.zip`（内含 `fqapp.app`），未做公证（notarization），
  首次打开需右键 → 打开，或执行
  `xattr -dr com.apple.quarantine /Applications/fqapp.app`

## 怎么构建

推荐直接用 GitHub Actions，不需要本机装 Xcode：

- 工作流：`.github/workflows/macos.yml`
- runner：`macos-15-intel`（GitHub 目前唯一的 x86_64 macOS runner，2027-08 退役）
- 触发：Actions → `macOS build (Intel x86_64, Ventura-compatible)` → Run workflow
- 产物在本次运行的 Artifacts 里，保留 14 天

本机构建（Apple Silicon 也可以，但必须让 Xcode 产出 x86_64，见下）：

```bash
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked   # 仅改了 Rust API 层时需要
scripts/build_macos.sh
```

在 Apple Silicon 上想拿到 x86_64 产物，需要显式指定架构（脚本默认按宿主架构
构建，并在校验阶段因架构不是 x86_64 而失败）：

```bash
flutter build macos --release --no-pub --config-only
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build
```

Rust 侧对应 `cargo build --release --target x86_64-apple-darwin`。

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
| `rust/build.rs` | C 解密核心原来**只在 Windows** 编译，现在 macOS 也编 | 这些 C 文件是纯 C11/POSIX，macOS clang 可直接编 |
| `rust/Cargo.toml` | `reqwest` 的 `blocking` feature 从 `cfg(windows)` 扩到 `cfg(any(windows, macos))` | `desktop_media` 用阻塞客户端做本地回环代理 |
| `rust/src/lib.rs` | `mod desktop_media` 的 cfg 门加 macOS | 同上 |
| `pubspec.yaml` | 新增 `media_kit_libs_macos_video` | libmpv（universal 产物，含 x86_64 与 arm64） |
| `pubspec.yaml` | `connectivity_plus` 锁到 `7.0.0` | 7.1.0 起用了 macOS 26 的 `NWPath.isUltraConstrained`，Xcode 16.4 编不过；本项目只用 `none/wifi/ethernet`，无 API 依赖 |
| `lib/services/secret_store.dart` | 新增系统钥匙串后端：通道不存在时（macOS/Windows runner 是 `flutter create` 原样输出，没有 `SecretStorePlugin`）改走 `flutter_secure_storage` | 原先桌面端 WebDAV 密码**根本存不下来**，只会报「当前环境不支持系统密钥库」 |
| `lib/services/secure_key_provider.dart` | `FlutterSecureStorage` 显式传 `MacOsOptions(useDataProtectionKeyChain: false)` | 插件默认走 data protection keychain，需要 `keychain-access-groups` 授权，ad-hoc 签名下 `SecItemAdd` 返回 `-34018`；拿不到 Hive 密钥就等于每次启动都换一把钥匙，本地数据全成空库 |
| `scripts/build_macos.sh` | 新增 | 生成 `macos/` 壳、覆盖 entitlements、编 Rust、打进 .app、签名、校验架构与 `minos` |
| `.github/workflows/macos.yml` | 新增 | Intel runner 上出可分发产物 |

`macos/` 目录本身没有提交——由构建脚本用 `flutter create --platforms=macos`
生成，避免手写 Xcode 工程。生成后脚本会覆盖两份 entitlements：关掉 App Sandbox，
打开 `disable-library-validation`（ad-hoc 签名下加载随包 dylib 需要）。

## 已知缺口

- **番茄书架导入不可用**：上游用 `webview_windows`（WebView2），macOS 需要
  WKWebView 实现。WebDAV 同步、JSON 备份/恢复不受影响。- **系统媒体键/正在播放不显示**：见上表 SMTC 一行。
- **未做公证**：自用没问题，分发给别人会被 Gatekeeper 拦一次。
- **构建产物的 Rust 桥接必须与已提交的 codegen 一致**：本次只动了 cfg 与
  非 `crate::api` 的模块，`rustContentHash` 不变，所以 CI 默认跳过 codegen。
  若启动即崩且报 content hash 不符，用 `run_codegen` 输入重跑一次。

## 排错对照

| 症状 | 原因 | 处理 |
|---|---|---|
| 启动报 `libfqapi_core.dylib` 打不开 | 核心没进 `Contents/MacOS` | 检查 `scripts/build_macos.sh` 第 5 步；确认 `cargo build --release` 产出 |
| 启动崩、提示 content hash / codegen version | 桥接与 Rust 源码不一致 | Actions 里勾 `run_codegen` 重跑 |
| 视频页黑屏、只有声音 | libmpv 没进包 | `pod install` 阶段要能联网拉 `media_kit_libs_macos_video` 的产物 |
| `pod install` 报 platform 版本不够 | `macos/Podfile` 的 `platform :osx` 低于某个 pod 的下限 | 把 `macos/Podfile` 提到 `11.0`，同时把 Runner 的 `MACOSX_DEPLOYMENT_TARGET` 提到同值（仍 ≤ 13，Ventura 可用） |
| `flutter build macos` 报 Xcode/CLT 版本不匹配 | runner 镜像的 Xcode 被换过 | 固定 runner 镜像标签，必要时用 `sudo xcode-select -s` 指向合格版本 |
| 打开 app 提示「已损坏」 | 未公证 + quarantine | `xattr -dr com.apple.quarantine fqapp.app` |
| 阅读时不阻止息屏 | `caffeinate` 没起来 | 手动 `which caffeinate`，macOS 自带 |
| `flutter test` 里 `Failed to load dynamic library 'kernel32.dll'` | `flutter test` 会把 `defaultTargetPlatform` 强制成 **android**（FLUTTER_TEST 环境变量），基于 `TargetPlatform` 的 `isMacDesktop` 在测试宿主上恒为 false | 挑原生库/原生二进制一律用 `dart:io` 的 `Platform`（本分支已加 `isMacHost` / `isWindowsHost`），不要用 `defaultTargetPlatform` |
| `xcodebuild` 报某插件 `has no member 'isUltraConstrained'` | 插件用了 macOS 26 SDK 的新 Swift API，`#available` 只在运行时判断，编译期仍需符号存在；Xcode 16.4 只有 macOS 15.5 SDK | 降该插件版本（`connectivity_plus` 锁 7.0.0），或换带 macOS 26 SDK 的构建机 |
| Android job 报 `Unable to satisfy pubspec.yaml using pubspec.lock` | 改了 `pubspec.yaml` 的依赖但没同步 `pubspec.lock`（Android 的 CI 带 `--enforce-lockfile`） | 跑一次 `flutter pub get` 并提交 lock；无 Flutter 环境时可按 pub.dev API 的 `archive_sha256` 手改 |
| 日志显示 app 已 Built 但 job 仍失败 | 脚本收尾的 `echo "... ${VAR}（...）"` 用了 `$VAR` 紧贴全角字符，被 bash 当成变量名一部分，`set -u` 报 unbound variable | 变量一律写 `${VAR}` |
| WebDAV 保存密码提示「当前环境不支持系统密钥库」 | 桌面 runner 没有 `fqapp/secrets` 通道（只有 Android 的 `SecretStorePlugin` 实现） | 已修：`SecretStore` 在通道缺失时改用系统钥匙串（macOS Keychain / Windows 凭据管理器） |
| 钥匙串报 `-34018 A required entitlement is not present` | 用了 data protection keychain，而它要求 `keychain-access-groups` 授权；本构建是 ad-hoc 签名 | 已修：所有 `FlutterSecureStorage` 都显式 `MacOsOptions(useDataProtectionKeyChain: false)`，退回传统 login keychain（本机用 `codesign -s -` 实测：DPKC 返回 -34018，传统 keychain 正常） |
| 首次打开后书架/历史是空的、重启又空 | 同上 `-34018`：Hive 密钥读不出来，每次启动生成一把新钥匙，旧加密盒只能当空盒处理 | 同上，换传统 keychain 后密钥才会持久化。日志里搜 `secure-key` 可确认当时是否降级 |
| 每次启动都弹「fqapp 想使用钥匙串中的机密信息」 | ad-hoc 签名的 cdhash 每次构建都变，钥匙串 ACL 不认新二进制 | 点「始终允许」；自用可在钥匙串访问里把该项 ACL 永久放行 |
