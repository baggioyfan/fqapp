/// 日志级别（从轻到重）。
enum LogLevel {
  debug,
  info,
  warn,
  error;

  String get label => switch (this) {
    LogLevel.debug => '调试',
    LogLevel.info => '资讯',
    LogLevel.warn => '警告',
    LogLevel.error => '错误',
  };

  String get token => switch (this) {
    LogLevel.debug => 'D',
    LogLevel.info => 'I',
    LogLevel.warn => 'W',
    LogLevel.error => 'E',
  };
}

/// 单条日志。
///
/// 隐私纪律沿用 `PlayerLoadSample` 的契约：只记方法/状态/耗时/标签，
/// **绝不记录 URL 中的参数、秘钥、请求体或任何敏感字段**。
class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  const LogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  String format() =>
      '[${level.token}] ${time.toIso8601String()} $tag: $message';
}

/// Sources available to the log viewer and export pipeline.
enum LogSource {
  app('应用'),
  rust('核心');

  const LogSource(this.label);
  final String label;
}

/// Value-only filter selection shared by the controller and filter sheet.
class LogFilterSelection {
  const LogFilterSelection({this.level, this.timeWindow});

  final LogLevel? level;
  final Duration? timeWindow;
}
