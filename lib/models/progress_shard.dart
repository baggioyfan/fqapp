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

  /// 本轮被剔除的记录数：本机导入书（`local_…`）、id 非法、作用域无法还原，
  /// 以及还原后撞成同一个 `kind:id` 的条目。以前这里只要混进一条，对端就会整
  /// 份拒收 —— 一条坏记录废掉全部进度。现在改成逐条剔除并计数，同步继续。
  final int dropped;

  const ProgressShard._({
    required this.createdAt,
    required this.history,
    required this.dropped,
  });

  factory ProgressShard.capture(List<Map<String, dynamic>> history) {
    final records = <Map<String, dynamic>>[];
    // 还原作用域键之后，两条不同的本机记录可能落成同一个 `kind:id`（例如
    // 一条旧的 `book/audio:123` 和一条 `audio/123`）。读者的 `sanitizeHistory`
    // 遇到重复会判「备份中有重复的进度」—— 又是一次整份拒收，所以在这里先去
    // 重：`history` 已按时间倒序，先到的那条就是更新的。
    final seen = <String>{};
    var dropped = 0;
    for (final record in history) {
      // 编码必须与读者共用同一套契约（[LibraryBackup.wireHistoryRecord]）：
      // 本机盒子的作用域键 `audio:123` 在这里还原成裸 id `123`，否则读者
      // 的 `sanitizeHistory` 会因冒号判整份文件无效。
      final wire = LibraryBackup.wireHistoryRecord(record);
      if (wire == null) {
        dropped++;
        continue;
      }
      if (!seen.add('${wire['kind']}:${wire['id']}')) {
        dropped++;
        continue;
      }
      records.add(wire);
    }
    return ProgressShard._(
      createdAt: DateTime.now(),
      history: List.unmodifiable(records),
      dropped: dropped,
    );
  }

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
      dropped: 0,
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

  /// 内容指纹：忽略 `createdAt`（每次 [capture] 都取当前时间），只比进度本身。
  ///
  /// 整包同步时用它判断云端那份分片是不是已经和本机一样 —— 一样就不重写，
  /// 免得白白换一个 ETag、多推几十 KB。
  String contentFingerprint() => canonicalJsonFingerprint(history);
}
