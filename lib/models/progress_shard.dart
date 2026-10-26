import 'dart:convert';
import 'dart:typed_data';

import 'library_backup.dart';

/// 热路径分片：**只有进度**。
///
/// 为什么要从整包里拆出来：进度是秒级变化的，书架/已看/时长是分钟~天级的。
/// 捆在一个文件里，就只能用最重的那份（阅读时长）的成本，去满足最急的那份
/// （进度）的时效 —— 读一页就要把整个书库 PUT 一遍。
///
/// 拆开之后退出路径是「一次 PROPFIND + 一次 PUT」，几十 KB。
/// 剩下的五项继续搭 `fqapp-sync.json` 那班车，因为它们没有各自的时效需求。
class ProgressShard {
  /// 与整包同目录，独立文件。
  static const fileName = 'progress.json';
  static const format = 'fqapp.progress';

  /// 独立版本号，**不复用** [LibraryBackup] 的版本：两者演进节奏不同。
  static const version = 1;

  /// 进度条目有 13 个字段，正常几十 KB；8 MB 只是防御上限。
  static const maxBytes = 8 * 1024 * 1024;
  static const _maxRecords = 10000;

  final DateTime createdAt;
  final List<Map<String, dynamic>> history;

  const ProgressShard._({required this.createdAt, required this.history});

  factory ProgressShard.capture(List<Map<String, dynamic>> history) =>
      ProgressShard._(
        createdAt: DateTime.now(),
        // 本机导入的书籍（`local_…`）不进去：它们在别的设备上打不开，而且
        // `sanitizeHistory` 读回来时会**拒绝整个文件**（「备份含无效作品标识
        // 或本地书籍记录」）。之前只有整包做了这个过滤，热路径没做 —— 分片里
        // 只要混进一条，另一台设备就再也解不开它，所有进度（不止这本书）都
        // 同步不过去。
        history: List.unmodifiable([
          for (final record in history)
            if (!LibraryBackup.isDeviceLocalId(
              '${record['contentId'] ?? record['id']}',
            ))
              record,
        ]),
      );

  factory ProgressShard.decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('进度文件超过 8 MB');
    }
    dynamic raw;
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      raw = jsonDecode(text);
    } on FormatException {
      throw const FormatException('进度文件不是有效的 UTF-8 JSON');
    }
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('进度文件格式无效');
    }
    if (raw['format'] != format) {
      throw const FormatException('不是什锦铺的进度文件');
    }
    if (raw['version'] != version) {
      throw const FormatException('不支持的进度文件版本');
    }
    final createdAt = raw['createdAt'];
    if (createdAt is! int || createdAt < 0) {
      throw const FormatException('进度文件时间无效');
    }
    final records = raw['history'];
    if (records is! List || records.length > _maxRecords) {
      throw const FormatException('进度列表无效或超过 10000 条');
    }
    return ProgressShard._(
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      // 与整包共用同一套字段校验，免得两处对同一条记录给出不同判断。
      history: LibraryBackup.sanitizeHistory(records),
    );
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'format': format,
        'version': version,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'history': history,
      }),
    ),
  );
}
