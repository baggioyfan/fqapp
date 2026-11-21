## 本版要点

**所有短剧「网络异常 / 播放服务暂时不可用 / 设备初始化失败」修好了**

2026-11-20 夜里开始，平板上的短剧几乎全军覆没：先是个别集提示「这一集暂时无法播放」，
接着整部剧变成「网络异常」，最后连剧集目录都报「设备初始化失败」。fq3 装的没动过，
说明变的是上游，不是我们。

抓日志 + 用真上游复现，链路是这样的：

1. 上游把短剧取流的 **player 门**（`POST /novel/player/multi_video_model/player/v1`）
   关掉了——照样回 `HTTP 200`，但 **0 字节**。真正还在出流的是同家族的
   `GET /reading/bookapi/video_tab/multi_video_model/v1/`（日志里的 `route=tab-b`）。
2. 这扇门能出流，但**载荷形状换了**：模型被挂深一层、还塞成了 JSON 字符串，
   `data.video_model_data.<video_id>.video_model`。我们的解析只认
   `data.<id>.video_model` 这一层，于是一份 23KB、货真价实带五档的响应被读成
   「body has no video payload」。
3. 读不到流之后，旧逻辑把它当成「这台设备被上游拒了」：`quarantine` 掉设备 + 立刻补池。
   注册预算只有 **4 台 / 10 分钟**（这是为了不被上游按 IP 拉黑特意钉死的），
   一集失败烧一台，几轮就见底；池一空，`video_detail`、目录、评论全部
   `get device: device registration throttled` —— 前端看到的就是「设备初始化失败」。

修的三处：

- **解析认得了新形状**：`data.video_model_data.<id>.video_model`（字符串或对象都行）、
  `data.<id>.video_model`、`data.video_model`、`data["1004"][<id>]` 一并收；
  请求指定了集号时优先取这一集，不拿邻近集的模型凑数。旧形状全部保留。
- **签名换成与社区同源的一版**：`x-khronos` / `x-helios` / `x-medusa` 三件套 + body 摘要
  `x-ss-stub`，与 hongguoTV（N3urda）以及 openhongguo PR 13 的实现逐字段对齐；
  `Content-Type` / `Content-Encoding` 由签名层一起给出，不再由调用方重复塞一个。
- **空体的语义收窄**：只有「0 字节」或「envelope 里连 `data` 都没有」才算身份级拒绝；
  「能解析、`data` 也在、只是这一集没有可播档位」不再去 quarantine 设备。
  这样即使真遇到无片源的集，也只影响那一集，不会连带把设备池和注册预算一起打光。

实测（真上游，2026-11-21 上午）：

- 修复前，从本机逐集探 10 集，**10/10 失败**；平板侧每集 3 次尝试全空。
- 修复后同样的 10 集，**10/10 成功**，五档齐全（1080P / 720P / 540P / 480P / 360P），
  全部走 `tab-b` 门。
- 平板日志里那条 `quarantined N device(s) after empty playback response` 不再出现。

**内建质量**

- 新增回归 `reads_the_video_tab_grouped_shape`：把上游那份分组 + 字符串化的载荷钉成用例，
  以后再改解析不会再退回「读不到 = 没片源」。
- 后端全量测试绿（169 个单测 + 20 个集成用例集，`cargo test` 全通过）。
- 签名层换成参考实现后补了对齐核对：请求 URL 的 query 顺序、头集合与上游实现逐项一致。

## 升级必读

签名与 `v1.0.204-fq2` 及之后的各版本**相同**（正式证书 `7d5397aa…3cde7a`）；
versionName 仍是 `1.0.205`，versionCode 提到 `213`（比上一版 `212` 大）——与上游同名的版本靠
code 递增区分，可直接覆盖安装，书架、进度、时长都保留。

仍在更早 debug 签名（`13f6a184…d9ac`）上的机器必须卸载重装 —— 清单 `android:allowBackup="false"`，
卸载会连书架、进度、时长一起清掉，先用旧版「设置 → 数据 → WebDAV 同步」推一次或导出备份。
**keystore 与密码请自行备份**，丢了无法升级。

桌面包是 ad-hoc 签名、未经公证，首次打开若提示「已损坏」：
`xattr -dr com.apple.quarantine fqapp.app`。以前装过旧包的，直接用这个 universal 包替换 `.app`
即可 —— 应用标识没变，书架与进度都跟着走，不需要先卸载。

> 这条修的是后端取流请求，属于内核侧改动，桌面端同样生效。

## 已知限制

- Android 只出 `arm64-v8a` 包（`com.fqapp.fqapp`）；桌面只覆盖 macOS 13+，
  universal 包内同时带 arm64 与 x86_64 两条切片，一个文件通吃。
- 如果上游以后把所有档位都锁进 H.266 灰度，本机仍然解不了 —— 那时会回到「这一集暂时无法
  播放」，需要换实现（自带 H.266 解码器）才能跟上。
- 「哪台设备给得出可解码片源」只记在内存里，冷启动后第一集仍可能先试一次；
  一次之后就会记住。
- 老板键在 Linux 上依赖 X11（`XGrabKey`）：Wayland 会话下全局热键不可用，
  设置页会显示为不支持，其它功能不受影响。
- 老板键在 macOS 上由 `scripts/build_macos.sh` 在构建时覆盖 `MainFlutterWindow.swift` 注入；
  直接用 Xcode 编译（不走脚本）时没有全局热键。
- Windows 便携包是**可选的**发布资产：只有发版时勾选了 windows 并构建成功，才会出现在这一版
  的发布页上（`*-windows-x64.zip`，解压即用，未做真机验收）。**本版未勾选**。
- Linux 包属于实验性构建：Arch 容器里能编出来，但没有做过安装、朗读、播放的真机验证，
  也不由发布流程自动上传。**本版未构建**。
- 亮度手势只在**翻页**阅读模式下生效；滚动阅读模式里上下滑是滚正文，不接管。
- 桌面端没有这条原生亮度桥，手势自动失效（不报错）。
- WebDAV 地址必须指向一个**已存在的子目录**（坚果云等不允许在根目录建文件）。
- 阅读时长、已看剧集搭「整包」的车，最长一天才上云；进度实时，想立刻对齐点「立即同步」。

## 校验

- APK：`arm64-v8a`，versionName `1.0.205` / versionCode `213`，显示名「什锦铺」
- macOS：universal，要求 macOS 13+
- 本版为全量重新编译：analyze 无告警 + 全量测试通过 + APK 签名与 16 KiB 对齐校验
  + 包内 Mach-O 架构校验
- 文件名的准确拼写与体积见本页末尾「资产」一节（发版时按实际上传的文件生成），
  sha256 见 `build-info.txt`
