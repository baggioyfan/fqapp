import 'package:flutter/foundation.dart';

/// Whether the app is running on a Linux desktop.
///
/// fork 不包含 Linux 移植（合并批次 v2 把 Linux 整簇列为「不收」），所以这里
/// 只保留各页面做平台分支判断所需的最小符号，不引入上游 `LinuxPlatform`
/// 那套窗口管理 / 媒体通道装配。上游页面用它决定「文件选择走系统对话框还是
/// 网页登录」，在非 Linux 平台上两者等价。
bool get isLinuxDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
