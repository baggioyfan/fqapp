import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'logging/log_codec.dart';
import 'logging/log_file_store.dart';
import 'logging/log_models.dart';

export 'logging/log_codec.dart' show formatLogLines;
export 'logging/log_file_store.dart' show FileLogWriter;
export 'logging/log_models.dart';
export 'logging/rust_log_source.dart';

/// 应用内日志核心：内存环形缓冲 + 捕获框架/未捕获异步异常 + 文件轮换持久化。
///
/// 使用方式：
/// - `AppLog.instance.install()` 在 `main()` 尽早调用一次，接管 `debugPrint`
///   与 `FlutterError.onError`；
/// - `AppLog.instance.startPersistence()` 异步开启文件轮换（失败只退回内存模式，
///   不阻塞启动）；
/// - 通过 `static` 助手 `d/i/w/e` 记录业务日志。
class AppLog with WidgetsBindingObserver {
  AppLog._();

  static final AppLog instance = AppLog._();

  static const int defaultCapacity = 1000;
  static const String logDirName = 'logs';
  static const String logFileName = FileLogWriter.fileName;

  final List<LogEntry> _entries = <LogEntry>[];

  /// 上次会话从落盘文件回读的条目：只用于查看与导出，不再写回文件（避免重复）。
  final List<LogEntry> _history = <LogEntry>[];
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  int _capacity = defaultCapacity;
  LogLevel _minLevel = LogLevel.debug;
  final LogFileStore _files = LogFileStore();

  DebugPrintCallback? _previousDebugPrint;
  FlutterExceptionHandler? _previousOnError;
  bool _observing = false;

  /// 当前可查看的日志 = 上次会话回读 + 本次会话内存缓冲（只读视图）。
  List<LogEntry> get entries => List.unmodifiable([..._history, ..._entries]);

  /// 是否已被 [install] 接管（用于测试与幂等保护）。
  bool installed = false;

  int get capacity => _capacity;
  LogLevel get minLevel => _minLevel;

  // ── 安装与捕获 ─────────────────────────────────────────────────────────

  /// 接管 [debugPrint] 与 [FlutterError.onError]，把框架与业务打印收进环形缓冲。
  ///
  /// 安全：始终链到上一层实现，保证原有控制台输出不被吞掉。
  void install({
    int capacity = defaultCapacity,
    LogLevel minLevel = LogLevel.debug,
  }) {
    if (installed) return;
    installed = true;
    _capacity = capacity;
    _minLevel = minLevel;

    final previousDebugPrint = debugPrint;
    _previousDebugPrint = previousDebugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      // 链到旧实现，保持原有控制台行为。
      previousDebugPrint(message, wrapWidth: wrapWidth);
      if (message == null || message.isEmpty) return;
      if (levelThreshold(LogLevel.debug)) {
        _emit(LogLevel.debug, 'flutter', message);
      }
    };

    final previousError = FlutterError.onError;
    _previousOnError = previousError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _emit(LogLevel.error, 'framework', details.toString());
      previousError?.call(details);
    };

    _attachLifecycle();
  }

  /// 还原被接管的 [debugPrint] 与 [FlutterError.onError]。
  ///
  /// 生产不需要（进程结束即还原），主要为测试与热重启后的卫生服务。
  void uninstall() {
    _detachLifecycle();
    _files.stopFlushing();
    if (!installed) return;
    if (_previousDebugPrint != null) debugPrint = _previousDebugPrint!;
    FlutterError.onError = _previousOnError;
    _previousDebugPrint = null;
    _previousOnError = null;
    installed = false;
  }

  /// 监听应用生命周期，退到后台/被杀前把缓冲刷进文件。
  ///
  /// 纯 Dart 单测没有 WidgetsBinding，此时静默跳过。
  void _attachLifecycle() {
    if (_observing) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } catch (_) {
      // 无 binding 的环境（单元测试）：不影响内存日志与落盘。
    }
  }

  void _detachLifecycle() {
    if (!_observing) return;
    _observing = false;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(flush());
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// 判定某个级别是否应当被记录（相对 `_minLevel`）。
  bool levelThreshold(LogLevel level) => level.index >= _minLevel.index;

  // ── 记录 ───────────────────────────────────────────────────────────────

  static void d(String tag, String message) =>
      instance._emit(LogLevel.debug, tag, message);
  static void i(String tag, String message) =>
      instance._emit(LogLevel.info, tag, message);
  static void w(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) => instance._emit(LogLevel.warn, tag, message, error: error, stack: stack);
  static void e(
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) =>
      instance._emit(LogLevel.error, tag, message, error: error, stack: stack);

  void _emit(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stack,
  }) {
    if (level.index < _minLevel.index) return;
    final entry = LogEntry(
      time: DateTime.now(),
      level: level,
      tag: sanitizeLogText(tag),
      // 捕获层脱敏：消息/错误/堆栈在进缓冲与落盘前统一过一遍
      // [sanitizeLogText]，一行日志里的 URL capability、Bearer、
      // Cookie 与敏感键值不会落进内存、文件或导出。
      message: sanitizeLogText(_compose(message, error, stack)),
    );
    _entries.add(entry);
    if (_entries.length > _capacity) _entries.removeAt(0);
    revision.value++;
    _files.append(entry);
  }

  String _compose(String message, Object? error, StackTrace? stack) {
    final buf = StringBuffer(message);
    if (error != null) buf.write('\n  error: $error');
    if (stack != null) buf.write('\n  ${stack.toString().trimRight()}');
    return buf.toString();
  }

  /// Compatibility entry point; all sources share the same redaction codec.
  @visibleForTesting
  static String sanitizeLogText(String input) => LogCodec.sanitizeText(input);

  /// 清空当前可查看的日志（历史 + 本次会话）；不删除落盘文件。
  void clear() {
    _history.clear();
    _entries.clear();
    revision.value++;
  }

  // ── 文件持久化 ─────────────────────────────────────────────────────────

  /// 开启文件轮换持久化。`directory` 仅供测试注入；生产用应用私有目录。
  ///
  /// 任何失败都只退化为「内存模式」，绝不抛给调用方（启动路径）。
  Future<void> startPersistence({
    Directory? directory,
    Duration flushInterval = const Duration(seconds: 5),
  }) => _files.start(
    resolveDirectory: () async {
      if (directory != null) return directory;
      try {
        final support = await getApplicationSupportDirectory();
        return Directory('${support.path}/$logDirName');
      } catch (_) {
        return null;
      }
    },
    bufferedEntries: () => List<LogEntry>.of(_entries),
    onHistory: (entries) {
      _history
        ..clear()
        ..addAll(
          entries.length > _capacity
              ? entries.sublist(entries.length - _capacity)
              : entries,
        );
      // A viewer can already be mounted while persistence starts asynchronously.
      if (entries.isNotEmpty) revision.value++;
    },
    flushInterval: flushInterval,
  );

  /// Parses restored application and core logs using the shared text contract.
  static List<LogEntry> parseLogLines(List<String> lines) =>
      LogCodec.parseLines(lines);

  /// Current file path, or null while logging only in memory.
  String? get filePath => _files.currentPath;

  /// Drains the serialized write/flush queue before assertions or shutdown.
  Future<void> flush() => _files.flush();

  // ── 导出与分享 ─────────────────────────────────────────────────────────

  /// 导出为纯文本（可用作剪贴板/分享正文）。覆盖上次会话回读 + 本次会话。
  String exportText({int? maxLines}) =>
      formatLogLines(entries, maxLines: maxLines);

  @visibleForTesting
  Future<void> resetForTest() async {
    uninstall();
    await _files.close();
    _history.clear();
    _entries.clear();
    revision.value++;
    _capacity = defaultCapacity;
    _minLevel = LogLevel.debug;
  }
}
