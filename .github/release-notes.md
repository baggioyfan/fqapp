# 什锦铺（本地改造版）

上游 [fqapp](https://github.com/ch6vip/fqapp) 的 Android 分支：原作者不做云同步，这里补上
WebDAV 双向同步（书架 / 进度 / 已看 / 搜索历史 / 阅读时长），同时保留手动备份导入导出。
桌面版同在本 Release 发布，两个架构各一个包：Apple Silicon 原生 arm64、Intel x64
（arm64 包在 Intel 上跑不了；x64 包在 Apple Silicon 上经 Rosetta 运行）。

## 本版 `v1.0.133-fq5`（进度镜像 + 桌面封面修复）

**听书与看书共享同一份章节进度**

- 同一本书「看到第几章」和「听到第几章」原来是两条独立记录，互不知晓。
  本版起统一为一份章节指针：无论哪台设备上看得更靠前还是听得更靠前，
  另一侧都自动跟上（只前进、不倒退，不会被旧进度拉回去）。
- 例：A 设备看书到 80 章，B 设备之前听到 60 章，B 重新登录同步后，B 上的
  看书和听书都会对齐到 80 章；反过来听书超前时，看书一侧同样跟上。
- 章内的细粒度位置（读到哪一页、听到哪一句）仍按模态各自保留，切换时不丢。

**桌面端一处修复**

- 短剧沉浸竖滑里尚未上屏的相邻卡片，兜底封面在桌面端也改为 contain
  完整显示。此前只修了已上屏的卡片，相邻卡仍会按宽度铺满裁切、只剩半截。

## ⚠️ 升级必读

签名与 `fq1`…`fq4` **相同**（正式证书 `7d5397aa…3cde7a`），可直接覆盖安装，
书架与进度都保留。

还在用更早 debug 签名（`13f6a184…d9ac`）的机器必须卸载重装 —— 清单
`android:allowBackup="false"`，卸载会连书架、进度、时长一起清掉，先用旧版
「设置 → 数据 → WebDAV 同步」推一次或导出备份。**keystore 与密码请自行备份**，丢了无法升级。

桌面包是 ad-hoc 签名、未经公证，首次打开若提示「已损坏」，先执行
`xattr -dr com.apple.quarantine fqapp.app`。

## 已知限制

- 取地址（`address`）在高峰时段仍要 3–4 秒，本版没动。
- 阅读时长、已看剧集搭「整包」的车，最长一天才上云；进度实时，想立刻对齐点「立即同步」。
- WebDAV 地址必须指向一个**已存在的子目录**（坚果云等不允许在根目录建文件）。
- Android 只出 `arm64-v8a` 包（`com.fqapp.fqapp`）；桌面版只覆盖 macOS 13+。

## 校验

- `fqapp-v1.0.133-fq5-arm64-v8a.apk`，versionName `1.0.133` / versionCode `138`，显示名「什锦铺」
- `fqapp-v1.0.133-fq5-macos-arm64.zip`，Apple Silicon 原生，macOS 13+
- `fqapp-v1.0.133-fq5-macos-x64.zip`，Intel（Apple Silicon 上经 Rosetta 运行），macOS 13+
- 流水线：analyze 无问题 + 全量测试通过 + APK 签名与 16 KiB 对齐校验
  + 包内 Mach-O 架构校验；sha256 与体积见 `build-info.txt`
