import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// 首页下拉刷新的口径：**手动刷新整页替换，只有冷启动才续接**。
///
/// 回归的是「下拉以后界面一帧都不动」：不带 `manualRefresh` 时 `load()` 会从
/// 落地缓存续接——把列表 trim 到用户停留的那张卡，同时把快照里每张卡的
/// `kind:id` 记进 `seen`，于是服务端回来的同一批卡被整份去重丢掉；只有真正
/// 的新卡会被追加到末尾，顶部看到的还是旧的。
void main() {
  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fqapp-home-refresh-test-',
    );
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    HomeFeedCache.hiveReady = false;
  });

  test('已浏览过的标签下拉刷新，整页换新而不是接着旧列表往下追加', () async {
    final cache = await _seededCache(['a', 'b', 'c'], lastVid: 'b');
    final harness = _Harness(cache, items: ['a', 'b', 'c', 'd']);
    addTearDown(harness.dispose);

    // 冷启动命中落地缓存：从停留的 b 继续。
    await harness.notifier.load();
    expect(harness.ids, ['b', 'c', 'd']);

    // 用户下拉。旧行为：还是续接，a 再也回不来，新卡全被 seen 吃掉，
    // 界面一帧不动；现在整页替换，从第一张卡重新排。
    await harness.notifier.load(manualRefresh: true);
    expect(harness.ids, ['a', 'b', 'c', 'd']);
    // 刷新必须是第一页（offset 0）：接着旧游标翻页只会拿回同一段。
    expect(harness.offsets, [0, 0]);
  });

  test('冷启动仍按快照续接，短剧流从上次那张卡继续', () async {
    final cache = await _seededCache(['a', 'b', 'c'], lastVid: 'b');
    final harness = _Harness(cache, items: ['a', 'b', 'c', 'd']);
    addTearDown(harness.dispose);

    await harness.notifier.load();

    // 停留的卡留在原位，新卡追加在后面——这是官方落地缓存的行为，不能砍。
    expect(harness.ids, ['b', 'c', 'd']);
  });

  test('下拉刷新期间旧内容留在屏上，不会塌成骨架', () async {
    final cache = await _emptyCache();
    final harness = _Harness(cache, items: ['a', 'b']);
    addTearDown(harness.dispose);

    await harness.notifier.load(manualRefresh: true);
    expect(harness.ids, ['a', 'b']);

    // 第二次刷新先挂住，模拟网络往返：这段时间屏上必须是上一份内容。
    final hold = Completer<void>();
    harness
      ..items = ['x']
      ..gate = hold.future;
    final pending = harness.notifier.load(manualRefresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(harness.ids, ['a', 'b']);
    expect(harness.isLoading, isTrue);

    hold.complete();
    await pending;
    expect(harness.ids, ['x']);
  });

  test('刷新失败时旧内容不丢，只挂上错误态', () async {
    final cache = await _emptyCache();
    final harness = _Harness(cache, items: ['a', 'b']);
    addTearDown(harness.dispose);

    await harness.notifier.load(manualRefresh: true);
    harness.fail = true;
    await harness.notifier.load(manualRefresh: true);

    expect(harness.ids, ['a', 'b']);
    expect(harness.error, isNotNull);
  });
}

/// 小说 tab（下标 1）：走 `tab_type=2` 的普通书城流，不碰「全部」的组合流
/// 与搜索兜底，测试只关心快照与替换逻辑。
const _tabIndex = 1;

class _Harness {
  _Harness(this.cache, {required this.items});

  final HomeFeedCache cache;
  List<String> items;
  Future<void>? gate;
  bool fail = false;
  final List<int> offsets = [];

  late final provider = NotifierProvider<HomeNotifier, HomeState>(
    () => HomeNotifier(
      initialTabIndex: _tabIndex,
      // 失败路径会退到搜索兜底；这里给空的，别让它真去打网络。
      searchLoader: (query, {int page = 1}) async => const [],
      homepageLoader:
          ({int tabType = 2, int offset = 0, String? sessionId}) async {
            offsets.add(offset);
            final pending = gate;
            if (pending != null) await pending;
            if (fail) throw ApiException('测试用失败');
            return HomepagePage(
              items: [for (final id in items) _item(id)],
              nextOffset: 10,
              sessionId: 'sess',
            );
          },
      feedCache: cache,
    ),
  );

  late final container = ProviderContainer();

  HomeNotifier get notifier => container.read(provider.notifier);
  HomeState get state => container.read(provider);
  List<String> get ids => state.items.map((item) => item.id).toList();
  bool get isLoading => state.isLoading;
  String? get error => state.error;

  void dispose() => container.dispose();
}

Future<HomeFeedCache> _emptyCache() async {
  HomeFeedCache.hiveReady = true;
  final cache = HomeFeedCache();
  await cache.warmUp();
  return cache;
}

/// 预先写一份落地缓存：`lastVid` 就是「用户停留的那张卡」。
Future<HomeFeedCache> _seededCache(
  List<String> ids, {
  required String lastVid,
}) async {
  final cache = await _emptyCache();
  await cache.save(
    _tabIndex,
    [for (final id in ids) _item(id)],
    hasMore: true,
    lastVid: lastVid,
  );
  return cache;
}

MediaItem _item(String id) => MediaItem(
  id: id,
  title: id,
  cover: '',
  author: '',
  badge: '',
  ep: '',
  kind: 'book',
);
