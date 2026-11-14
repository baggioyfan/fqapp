import 'package:flutter/foundation.dart';

import 'desktop_platform.dart';

/// 视频播放是否可用。
///
/// 视频依赖原生播放器：Android 走 ExoPlayer 平台通道（`fqapp/native_player`），
/// 桌面走 media_kit（`DesktopPlatform.invoke` 的 `fqapp/native_player` 分支）。
/// iOS 首版没有播放器实现，直接进入播放页会抛 `MissingPluginException`，所以
/// 入口整体降级为「暂不支持」。
///
/// 上游这里只写了 [isWindowsDesktop]（上游没有 macOS 端）。fork 的 macOS 与
/// Windows 走同一套 media_kit 实现，必须一起放行，否则 macOS 的视频入口会被
/// 误判为「暂不支持」。
///
/// Linux **不在**其中：fork 没有 Linux 构建产物，上游也把 Linux 视为尚未接
/// 视频播放（见 `8022c8cd` 的用例「D4 Linux must reject playback before
/// navigation」）。要放开 Linux 得连那批用例一起改。
bool get supportsVideoPlayback =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        isWindowsDesktop ||
        isMacDesktop);
