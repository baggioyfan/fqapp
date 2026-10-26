import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/library_store.dart';

/// 听书（`audio:<id>`）与看书（裸 `<id>`）两条进度线共享章节指针：
/// 本机写入（[LibraryStore.addHistory]）与云端合并（[LibraryStore.mergeBackup]）
/// 都要把另一条线往前带；只进不退、只更新不创建，章内锚点归零。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = LibraryStore.instance;
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('fqapp-mirror-test-');
    Hive.init(directory.path);
    await store.init();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> audio({
    required String id,
    required int episode,
    String? chapterId,
    int chapterCount = 120,
    int time = 1000,
    double position = 320.0,
    double progress = 0.5,
  }) => {
    'id': 'audio:$id',
    'contentId': id,
    'bookId': id,
    'kind': 'audio',
    'title': '听书 $id',
    'cover': 'cover-$id',
    'episode': episode,
    'chapterId': ?chapterId,
    'chapterCount': chapterCount,
    'position': position,
    'progress': progress,
    'time': time,
  };

  Map<String, dynamic> book({
    required String id,
    required int episode,
    String? chapterId,
    int chapterCount = 120,
    int time = 1000,
    double position = 55.0,
    double maxScroll = 100.0,
    int textOffset = 123,
  }) => {
    'id': id,
    'bookId': id,
    'kind': 'book',
    'title': '看书 $id',
    'episode': episode,
    'chapterId': ?chapterId,
    'chapterCount': chapterCount,
    'position': position,
    'maxScroll': maxScroll,
    'textOffset': textOffset,
    'positionVersion': 2,
    'progress': 0.3,
    'time': time,
  };

  test('听书进度把已有的看书线往前带', () async {
    // 先有看书线（读到第 10 章），听书才有的可带。
    await store.addHistory(book(id: 'b1', episode: 9, chapterId: 'c10'));
    await store.addHistory(audio(id: 'b1', episode: 49, chapterId: 'c50'));

    final text = await store.historyEntry('b1');
    expect(text!['kind'], 'book');
    expect(text['episode'], 49);
    expect(text['chapterId'], 'c50');
    expect(text['chapterCount'], 120);
    // 章内锚点归零：换章后文字位置本来就不成立，从章首继续。
    expect(text['textOffset'], 0);
    expect(text['position'], 0.0);
    expect(text['positionVersion'], 2);
    // 书级百分比由章节指针换算，书架能直接显示「第 50/120 章」。
    expect(text['progress'], closeTo(49 / 120, 1e-9));
    expect(text['time'], 1000);
  });

  test('看书进度把已有的听书线往前带', () async {
    await store.addHistory(audio(id: 'b2', episode: 4, chapterId: 'c5'));
    await store.addHistory(
      book(id: 'b2', episode: 29, chapterId: 'c30', chapterCount: 100),
    );

    final listened = await store.historyEntry('audio:b2');
    expect(listened!['kind'], 'audio');
    expect(listened['contentId'], 'b2');
    expect(listened['episode'], 29);
    expect(listened['episodeId'], 'c30');
    expect(listened['chapterCount'], 100);
    // 播放秒数归零：从这一章的开头接着听。
    expect(listened['position'], 0.0);
    expect(listened['progress'], 0.0);
    expect(listened.containsKey('textOffset'), isFalse);
  });

  test('单边进度不凭空造兄弟记录', () async {
    await store.addHistory(audio(id: 'b0', episode: 49, chapterId: 'c50'));

    expect(await store.historyEntry('b0'), isNull);
    expect(store.historySnapshot(), hasLength(1));
  });

  test('只进不退：回头听旧章不把看书线往回拽', () async {
    await store.addHistory(
      book(id: 'b3', episode: 49, chapterId: 'c50', time: 3000),
    );
    await store.addHistory(
      audio(id: 'b3', episode: 19, chapterId: 'c20', time: 4000),
    );

    final text = await store.historyEntry('b3');
    expect(text!['episode'], 49);
    expect(text['time'], 3000);
  });

  test('同一章的重复写入不重置兄弟线的章内进度', () async {
    await store.addHistory(book(id: 'b4', episode: 49, chapterId: 'c50'));
    final before = (await store.historyEntry('b4'))!['time'];

    await store.addHistory(
      audio(id: 'b4', episode: 49, chapterId: 'c50', time: 2000),
    );

    final text = await store.historyEntry('b4');
    expect(text!['episode'], 49);
    expect(text['time'], before);
  });

  test('裸键被其它媒体占用时不覆盖', () async {
    await store.addHistory({
      'id': 'v1',
      'kind': 'video',
      'title': '剧一',
      'episode': 3,
      'time': 500,
    });
    await store.addHistory(
      audio(id: 'v1', episode: 9, chapterId: 'e10', time: 600),
    );

    final bare = await store.historyEntry('v1');
    expect(bare!['kind'], 'video');
    expect(bare['episode'], 3);
  });

  test('云端合并把兄弟线前带（A 设备听 50 章，B 设备文字进度跟上）', () async {
    await store.addHistory(
      book(id: 'b5', episode: 9, chapterId: 'c10', time: 1000),
    );

    final merged = await store.mergeBackup(
      history: [
        // 云端记录存的是内容 id（不带作用域），合并时才加上 `audio:` 键。
        {
          ...audio(id: 'b5', episode: 49, chapterId: 'c50', time: 5000)
            ..remove('id'),
          'id': 'b5',
        },
      ],
      watched: const {},
      daily: const {},
      books: const <({String id, String kind, Map<String, double> devices})>[],
    );
    expect(merged.history, 1);

    final text = await store.historyEntry('b5');
    expect(text!['episode'], 49);
    expect(text['chapterId'], 'c50');
    expect(text['textOffset'], 0);
  });

  test('云端看书记录更靠后时，本机听书线跟着上（双设备换向场景）', () async {
    // B 设备之前听到 60 章（episode 59）。
    await store.addHistory(
      audio(id: 'b6', episode: 59, chapterId: 'c60', time: 1000),
    );

    // A 设备看到 80 章（episode 79）上云，B 重新登录后拉到它。真实云端
    // 记录经 LibraryBackup._common 一定带 id/kind，这里保持同形。
    final merged = await store.mergeBackup(
      history: [
        book(id: 'b6', episode: 79, chapterId: 'c80', time: 5000),
      ],
      watched: const {},
      daily: const {},
      books: const <({String id, String kind, Map<String, double> devices})>[],
    );
    expect(merged.history, 1);

    // 看书线到 80 章之外，听书线也被前带到 80 章、播放秒数归零 ——
    // 两台设备重新对齐后，B 上「继续收听」就是第 80 章开头。
    final text = await store.historyEntry('b6');
    expect(text!['episode'], 79);
    final listened = await store.historyEntry('audio:b6');
    expect(listened!['episode'], 79);
    expect(listened['episodeId'], 'c80');
    expect(listened['position'], 0.0);
    expect(listened['time'], 5000);
  });
}
