import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/progress_shard.dart';

/// 契约守卫：**写出去的东西必须能被自己读回来**。
///
/// 线上 `id` 只认作品裸 id（`^[a-zA-Z0-9_-]{1,128}$`），而本机盒子里的听书/
/// 漫画记录是作用域键 `audio:123`。分片编码器曾经把这些键原样写进 `id`，于是
/// 读者的 `sanitizeHistory` 判定整份文件「含无效作品标识」——所有设备（包括
/// 写它的那一台）的进度一起停摆；又因为坏记录常驻本机，每次重写只是把同一份
/// 毒再写一遍，永远自愈不了。
void main() {
  Map<String, dynamic> scoped(String kind, String bareId) => {
    'id': '$kind:$bareId',
    'contentId': bareId,
    'kind': kind,
    'title': '书 $bareId',
    'time': 1000,
    'episode': 12,
    'progress': 0.4,
  };

  test('作用域键写出去是裸 id，且同一份字节能读回来', () {
    final shard = ProgressShard.capture([
      scoped('audio', '7673107019712187454'),
    ]);
    expect(shard.dropped, 0);

    final decoded = ProgressShard.decode(shard.encode());

    expect(decoded.history.single['id'], '7673107019712187454');
    expect(decoded.history.single['kind'], 'audio');
    expect(decoded.history.single['episode'], 12);
    // `contentId` 不是线上字段：读回来也不该带，否则两次编码的字节不一致。
    expect(decoded.history.single.containsKey('contentId'), isFalse);
  });

  test('本机导入书的记录被剔除并计数，其余照常同步', () {
    final shard = ProgressShard.capture([
      scoped('audio', '111'),
      {'id': 'local_1759_ab', 'kind': 'book', 'time': 1000},
      scoped('book', '222'),
    ]);

    expect(shard.dropped, 1);

    final decoded = ProgressShard.decode(shard.encode());
    expect(decoded.history.map((e) => e['id']), ['111', '222']);
  });

  test('作用域键还原后撞成同一条时只留一条，不让读者判重复', () {
    final shard = ProgressShard.capture([
      // 时间倒序：先到的这条才是更新的。
      {...scoped('audio', '555'), 'time': 3000},
      {
        'id': '555',
        'kind': 'audio',
        'title': '旧记录',
        'time': 1000,
        'episode': 2,
        'progress': 0.1,
      },
    ]);

    expect(shard.dropped, 1);

    final decoded = ProgressShard.decode(shard.encode());
    expect(decoded.history.single['time'], 3000);
  });

  test('非法的章内锚点只丢锚点，不丢整条进度', () {
    final decoded = ProgressShard.decode(
      ProgressShard.capture([
        {
          ...scoped('book', '333'),
          'chapterId': 'local_chapter_7',
          'bookId': 'audio:333',
        },
      ]).encode(),
    );

    expect(decoded.history.single['id'], '333');
    expect(decoded.history.single.containsKey('chapterId'), isFalse);
    // 合法的 bookId 只解掉作用域前缀，不整条丢。
    expect(decoded.history.single['bookId'], '333');
  });

  test('整包（手动导出）走同一套整理，作用域键同样还原', () {
    final decoded = LibraryBackup.decode(
      LibraryBackup.capture(
        shelf: const [],
        shelfRemoved: const {},
        history: [scoped('manga', '444')],
        watched: const {},
        daily: const {},
        books: const [],
        searchHistory: const <String>[],
      ).encode(),
    );

    expect(decoded.history.single['id'], '444');
    expect(decoded.history.single['kind'], 'manga');
  });
}
