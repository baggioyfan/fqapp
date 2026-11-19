import 'log_codec.dart';
import 'log_models.dart';

/// Rust 核心日志（`core_log` 落盘副本）的读取入口。
///
/// Rust 侧只把日志写进 `runtime_dir/rust.log` —— Android 应用读不到自己的 logcat，
/// 这是真机上唯一的观测面。读取实现由宿主注入（`main()` 接
/// `BackendService.rustLogFile`），日志页的「Rust」视图据此展示；未注入时视为
/// 不可用，页面给空态而不是报错。
class RustLogSource {
  const RustLogSource._();

  /// 返回文件全文；文件不存在返回 null。
  static Future<String?> Function()? reader;

  static Future<List<LogEntry>?> readEntries() async {
    final text = await read();
    return text == null ? null : parseText(text);
  }

  /// core_log uses UTC but its legacy timestamp omits a timezone suffix.
  /// Keep that source rule here so polling and export agree without changing
  /// application history or timestamps that already carry an explicit zone.
  static List<LogEntry> parseText(String text) =>
      LogCodec.parseText(text, unzonedTimestampsAreUtc: true);

  static Future<String?> read() async {
    final read = reader;
    if (read == null) return null;
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }
}
