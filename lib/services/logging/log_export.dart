import 'log_codec.dart';
import 'log_models.dart';

/// An immutable payload captured before the user chooses a platform action.
class LogExportSnapshot {
  LogExportSnapshot({
    required this.source,
    required Iterable<LogEntry> entries,
    required this.time,
  }) : entries = List<LogEntry>.unmodifiable(entries);

  final LogSource source;
  final List<LogEntry> entries;
  final DateTime time;

  String get fileName =>
      'fqapp-${source.name}-logs-${time.microsecondsSinceEpoch}.txt';

  String text({required bool all}) =>
      'fqapp ${source.label}日志\n'
      '导出时间：${time.toIso8601String()}\n'
      '范围：${all ? '当前来源全部可用日志' : '当前筛选结果'}\n'
      '共 ${entries.length} 条\n\n${formatLogLines(entries)}';
}

/// Combined export keeps sources distinct and reports an unavailable core file.
/// Null is not an empty file: it must never be presented as a successful read.
class CombinedLogExportSnapshot {
  CombinedLogExportSnapshot({
    required Iterable<LogEntry> appEntries,
    required Iterable<LogEntry>? rustEntries,
    required this.time,
  }) : appEntries = List<LogEntry>.unmodifiable(appEntries),
       rustEntries = rustEntries == null
           ? null
           : List<LogEntry>.unmodifiable(rustEntries);

  final List<LogEntry> appEntries;
  final List<LogEntry>? rustEntries;
  final DateTime time;

  bool get isEmpty => appEntries.isEmpty && (rustEntries?.isEmpty ?? true);
  String get coreSummary =>
      rustEntries == null ? '未获取（文件不存在或读取失败）' : '${rustEntries!.length} 条';
  String get fileName => 'fqapp-all-logs-${time.microsecondsSinceEpoch}.txt';

  String get text =>
      'fqapp 应用 + 核心日志\n'
      '导出时间：${time.toIso8601String()}\n'
      '范围：应用与核心全部可用日志，不受筛选影响\n'
      '应用日志：${appEntries.length} 条\n'
      '核心日志：$coreSummary\n\n'
      '===== 应用日志 =====\n'
      '${formatLogLines(appEntries)}\n\n'
      '===== 核心日志 =====\n'
      '${rustEntries == null ? coreSummary : formatLogLines(rustEntries!)}\n';
}
