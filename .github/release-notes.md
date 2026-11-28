## 本版要点

**桌面端（macOS / Linux）在线播放修好了**

上一版（`v1.0.207-fq1`）之后只做了一件事：把「本机每一集都播不起来」这条修掉，
其余功能与 fq1 一致。

### 修复：桌面播放器通道根本没装起来

现象是取地址明明成功（`api GET /videos 200`，约 0.3–0.9 s），`create` 却在 **1 ms 内**
失败，日志里 `errorCode` / `httpStatusCode` 全是 null，并跟一条
`MissingPluginException(No implementation found for method listen on channel
fqapp/native_player/events)` —— 不是 CDN 403，是播放器通道不存在。

根因在 11-23 那次「桌面端整体换上游 Fluent 基底」：`DesktopPlatform.initialize()` 的首行
守卫被写成「仅 Windows」，macOS 与 Linux 直接 return，`PlatformChannels.invoke/events`
从未装配，`NativePlayer` 于是退回真正的 MethodChannel（一个没人接的通道）。

连带失效的三处：

- **桌面在线播放**（macOS / Linux）：每一集都失败，只有缓存下来的离线文件能播。
- **听书 TTS 初始化**：`initializeSpeech()` 在 return 之后，从未执行。
- **关窗前把进度推回 WebDAV**：依赖 `setPreventClose` → `beforeClose`，同样没装配 ——
  macOS 上的「关窗口自动同步」从 11-23 起其实一次都没跑过。

改法：通道装配抽成 `installPlatformChannels()`，按「是否桌面平台」判定，并放在
`initialize` 的最前面（它不依赖任何插件，先装再初始化窗口与 media_kit）。标题栏样式
按平台分开：Windows 保持 Fluent 的无边框自绘壳，macOS / Linux 回到系统标题栏，红黄绿
三个按钮与拖拽行为跟系统一致。

新增 3 条守卫用例：macOS 必须装配、Linux 必须装配、Android 不装配。这段装配此前
一条测试都没有盯着，正是它能静默挂掉一周的原因。

**内建质量**

- CI 实测：analyze 无告警 + 全量 Dart 测试通过（含新增的 3 条通道守卫）。

## 升级必读

签名与 `v1.0.204-fq2` 及之后的各版本**相同**（正式证书 `7d5397aa…3cde7a`）；
versionName 仍是 `1.0.207`，versionCode 从 `216` 提到 `217` —— 可直接覆盖安装，
书架、进度、时长都保留。

仍在更早 debug 签名（`13f6a184…d9ac`）上的机器必须卸载重装 —— 清单 `android:allowBackup="false"`，
卸载会连书架、进度、时长一起清掉，先用旧版「设置 → 数据 → WebDAV 同步」推一次或导出备份。
**keystore 与密码请自行备份**，丢了无法升级。

桌面包是 ad-hoc 签名、未经公证，首次打开若提示「已损坏」：
`xattr -dr com.apple.quarantine fqapp.app`。以前装过旧包的，直接用这个 universal 包替换 `.app`
即可 —— 应用标识没变，书架与进度都跟着走，不需要先卸载。

## 已知限制

- Android 只出 `arm64-v8a` 包（`com.fqapp.fqapp`）；桌面只覆盖 macOS 13+，
  universal 包内同时带 arm64 与 x86_64 两条切片，一个文件通吃。
- **上游正在灰度 bytevc2（H.266 私有外壳）片源，本 fork 仍不内置 H.266 解码器。**
  取流声明 `device_level=5`，服务端正常会给 H.265，不会拿到 bytevc2；若某集所有档位
  都只给 bytevc2，仍会提示「这一集暂时无法播放」。桌面端也没有可用的 VVC 硬解通路。
- **播放统计里的码率、带宽、解码器来自 Android 原生通道**：桌面端没有这条通道，
  相应字段显示为不可用，其余项（分辨率、位置、倍速、加载来源）照常。
- 取流走的是上游当前行为（F21 = 312）。上游若再次调整报文字段，需要跟着上游协议仓库更新。
- 「哪扇门、哪台设备给得出可解码片源」只记在内存里，冷启动后第一集仍可能多试一两次。
- 老板键在 Linux 上依赖 X11（`XGrabKey`）：Wayland 会话下全局热键不可用，
  设置页会显示为不支持，其它功能不受影响。
- 老板键在 macOS 上由 `scripts/build_macos.sh` 在构建时覆盖 `MainFlutterWindow.swift` 注入；
  直接用 Xcode 编译（不走脚本）时没有全局热键。
- Windows 便携包 `*-windows-x64.zip` 解压即用，未做真机验收。**本版已勾选构建。**
- Linux Arch 包（`*.pkg.tar.zst`）属于实验性构建：容器里能编出来，但没有做过安装、朗读、
  播放的真机验证。它不进发布流程的自动上传，是**手工补传**到本页的，装坏了请当作预期内。
- 亮度手势只在**翻页**阅读模式下生效；滚动阅读模式里上下滑是滚正文，不接管。
- 桌面端没有这条原生亮度桥，手势自动失效（不报错）。
- WebDAV 地址必须指向一个**已存在的子目录**（坚果云等不允许在根目录建文件）。
- 阅读时长、已看剧集搭「整包」的车，最长一天才上云；进度实时，想立刻对齐点「立即同步」。

## 校验

- APK：`arm64-v8a`，versionName `1.0.207` / versionCode `217`，显示名「什锦铺」
- macOS：universal，要求 macOS 13+
- Windows：x64 便携包（本版带）
- Linux：Arch 包，实验性，手工补传
- 本版为全量重新编译：analyze 无告警 + 全量测试通过 + APK 签名与 16 KiB 对齐校验
  + 包内 Mach-O 架构校验
- 文件名的准确拼写与体积见本页末尾「资产」一节（发版时按实际上传的文件生成），
  sha256 见 `build-info.txt`
