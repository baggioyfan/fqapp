import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'dart:io';

import '../src/rust/frb_generated.dart';
import 'desktop_media.dart' show desktopCoreLibraryPath;

/// 初始化 flutter_rust_bridge 运行时（原生平台）。
///
/// iOS 上 Rust 核心是以**静态库**形式整体链进 App 主二进制的（iOS 不允许像
/// Android 那样从包内 dlopen `libfqapi_core.so`，见 `ios/Flutter/Debug.xcconfig`
/// 里的 `-force_load`），所以没有可 `DynamicLibrary.open()` 的文件。此路径下
/// FRB 必须走 `ExternalLibrary.process()`，从进程自身导出符号里查 Rust 入口。
///
/// 其它原生平台（Android/Windows/macOS）保持 FRB 默认的按文件名加载。
///
/// Linux 例外：`.so` 装在可执行文件旁的 `lib/` 里（Arch 包按 FHS 布局把
/// 库和 launcher 分开），默认的「按文件名在 rpath 里找」在这套打包里不可靠，
/// 所以直接给出绝对路径交给 `ExternalLibrary.open`。
Future<void> initRustRuntime() {
  if (Platform.isIOS) {
    // iKnowHowToUseIt 是 FRB 对"静态链接 + process()"这种用法的确认开关：
    // 它要求整个 App 里只有一个用到 flutter_rust_bridge 的包（本项目满足）。
    return RustLib.init(
      externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
    );
  }
  if (Platform.isLinux) {
    return RustLib.init(
      externalLibrary: ExternalLibrary.open(desktopCoreLibraryPath()),
    );
  }
  return RustLib.init();
}
