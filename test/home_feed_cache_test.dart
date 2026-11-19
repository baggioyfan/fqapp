import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/home_cell.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/home_feed_cache.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

MediaItem _item(String id, {String kind = 'video'}) => MediaItem(
  id: id,
  title: '剧 $id',
  cover: 'https://example.com/$id.jpg',
  author: '作者',
  badge: '12集',
  ep: '',
  kind: kind,
  tag: MediaTag(text: '爆款', lightColors: ['#FF0000']),
  intro: '简介 $id',
  followerCount: 7,
  categories: const ['都市'],
  episodeListText: '观看全集·12集',
);

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  final videoTabIndex = HomeNotifier.tabs.indexOf('视频');

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'fqapp-home-feed-cache-test-',
    );
    Hive.init(directory.path);
  });

  tearDown(() async {
    await Hive.close();
    HomeFeedCache.hiveReady = false;
  });

  test('media item JSON round trip preserves every rendered field', () {
    final item = _item('a1');
    final restored = MediaItemJson.fromJson(item.toJson());
    expect(restored, isNotNull);
    expect(restored!.id, item.id);
    expect(restored.title, item.title);
    expect(restored.cover, item.cover);
    expect(restored.author, item.author);
    expect(restored.badge, item.badge);
    expect(restored.kind, item.kind);
    expect(restored.tag?.text, '爆款');
    expect(restored.tag!.colorsFor(dark: false), item.tag!.lightColors);
    expect(restored.tag?.hasColors, isTrue);
    expect(restored.intro, item.intro);
    expect(restored.followerCount, 7);
    expect(restored.categories, item.categories);
    expect(restored.episodeListText, item.episodeListText);
  });

  test('a truncated record cannot resurrect an item', () {
    expect(MediaItemJson.fromJson({'id': 'x', 'tag': 3}), isNull);
  });

  test('save then load returns the stored snapshot', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(2, [_item('a'), _item('b')], hasMore: true);
    final snapshot = cache.load(2);
    expect(snapshot, isNotNull);
    expect(snapshot!.items.map((item) => item.id), ['a', 'b']);
    expect(snapshot.hasMore, isTrue);
    expect(snapshot.lastVid, isNull);
    await cache.close();
  });

  test('lastVid round trips through save and load', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(1, [_item('a')], hasMore: true, lastVid: 'a');
    expect(cache.load(1)!.lastVid, 'a');
    // Empty strings and missing keys both restore as null.
    await cache.save(1, [_item('a')], hasMore: true, lastVid: '');
    expect(cache.load(1)!.lastVid, isNull);
    await cache.close();
  });

  test('cells round trip and old stream layouts fall back', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    const rankCell = HomeCell(
      showType: 511,
      name: '排行榜',
      id: 'rank-1',
      style: {'cover_size': 2},
      items: [],
      children: [
        HomeCell(
          showType: 512,
          name: '',
          id: '',
          style: {},
          items: [],
          children: [],
        ),
      ],
      url: 'dragon1967://rank',
      extra: {
        'rank_with_category_data': {'boards': 3},
      },
    );
    final gridCell = HomeCell(
      showType: 384,
      name: '猜你喜欢',
      id: '',
      style: const {},
      items: [_item('c1'), _item('c2')],
      children: const [],
    );
    await cache.save(
      4,
      [_item('c1'), _item('c2')],
      hasMore: true,
      lastVid: 'c2',
      cells: [rankCell, gridCell],
    );

    final snapshot = cache.load(4)!;
    expect(snapshot.cells, hasLength(2));

    final restoredRank = snapshot.cells.first;
    expect(restoredRank.showType, 511);
    expect(restoredRank.name, '排行榜');
    expect(restoredRank.id, 'rank-1');
    expect(restoredRank.url, 'dragon1967://rank');
    expect(restoredRank.style['cover_size'], 2);
    expect(restoredRank.extra['rank_with_category_data'], {'boards': 3});
    // Children recurse, so nested blocks survive the round trip too.
    expect(restoredRank.children, hasLength(1));
    expect(restoredRank.children.single.showType, 512);

    final restoredGrid = snapshot.cells.last;
    expect(restoredGrid.name, '猜你喜欢');
    expect(restoredGrid.items.map((item) => item.id), ['c1', 'c2']);
    // The card keeps its rendered fields, badge included.
    expect(restoredGrid.items.first.tag?.text, '爆款');

    // v1.0.205 wrote v2 cells before streamLayout existed. Their 385 order may
    // be corrupted, but the flat items and video position are still valid.
    final box = await Hive.openBox('home_feed_cache_v1');
    final raw = Map<String, dynamic>.from(box.get('4') as Map);
    expect(raw['streamLayout'], 1);
    raw.remove('streamLayout');
    await box.put('4', raw);
    final migrated = cache.load(4)!;
    expect(migrated.items.map((item) => item.id), ['c1', 'c2']);
    expect(migrated.lastVid, 'c2');
    expect(migrated.cells, isEmpty);

    // The migration is scoped to stream layouts: a drama cell and a rank-only
    // record predate this marker too and must stay usable.
    final videoCell = HomeCell(
      showType: 407,
      name: '视频流',
      id: 'video-1',
      style: const {},
      items: [_item('video')],
      children: const [],
    );
    await cache.save(
      4,
      [_item('video')],
      hasMore: true,
      cells: [rankCell, videoCell],
    );
    final preservedRaw = Map<String, dynamic>.from(box.get('4') as Map);
    preservedRaw.remove('streamLayout');
    await box.put('4', preservedRaw);
    final preserved = cache.load(4)!;
    expect(preserved.cells.map((cell) => cell.showType), [511, 407]);
    expect(preserved.cells.first.name, '排行榜');
    expect(preserved.cells.last.name, '视频流');
    await cache.close();
  });

  test(
    'a snapshot without a cells field degrades to an empty cell list',
    () async {
      HomeFeedCache.hiveReady = true;
      final cache = HomeFeedCache();
      // save() without cells writes exactly the pre-cells record shape.
      await cache.save(7, [_item('a')], hasMore: true);

      // Pin the old format: the record on disk carries no `cells` key.
      final box = await Hive.openBox('home_feed_cache_v1');
      final raw = Map<String, dynamic>.from(box.get('7') as Map);
      expect(raw.containsKey('cells'), isFalse);

      final snapshot = cache.load(7)!;
      expect(snapshot.items.map((item) => item.id), ['a']);
      expect(snapshot.cells, isEmpty);
      await cache.close();
    },
  );

  test('load returns null before the box exists and after the TTL', () async {
    final cache = HomeFeedCache();
    expect(cache.load(0), isNull);

    HomeFeedCache.hiveReady = true;
    await cache.save(0, [_item('a')], hasMore: false);
    expect(cache.load(0), isNotNull);

    // Rewrite savedAt far into the past through the same box. Hive returns
    // the box singleton the cache already holds, so no reopen is needed.
    final box = await Hive.openBox('home_feed_cache_v1');
    final raw = Map<String, dynamic>.from(box.get('0') as Map);
    raw['savedAt'] =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(days: 4).inMilliseconds;
    await box.put('0', raw);
    expect(cache.load(0), isNull);
    await cache.close();
  });

  test('a 看剧 grid cold start replaces despite playback capability', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      dramaTabIndex,
      [_item('cached-1'), _item('cached-2')],
      hasMore: true,
      lastVid: 'cached-2',
    );

    final networkStarted = Completer<void>();
    final releaseNetwork = Completer<void>();
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      // The drama page opts into playback resume, but 看剧 is tab_type=8 and
      // renders a grid, so the snapshot must still be replaced.
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: dramaTabIndex,
        usesLocalTabs: true,
        resumeVideoFeed: true,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async {
              networkStarted.complete();
              await releaseNetwork.future;
              return HomepagePage(
                items: [_item('fresh-1')],
                nextOffset: 1,
                sessionId: null,
              );
            },
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    final loading = notifier.load();

    // Before the network answers, the snapshot is already on screen.
    expect(container.read(provider).items.map((item) => item.id), [
      'cached-1',
      'cached-2',
    ]);
    expect(container.read(provider).isLoading, isTrue);

    releaseNetwork.complete();
    await loading;
    expect(container.read(provider).items.map((item) => item.id), ['fresh-1']);
  });

  test(
    'a failed refresh keeps the cached feed visible with the error',
    () async {
      HomeFeedCache.hiveReady = true;
      final cache = HomeFeedCache();
      await cache.save(3, [_item('kept')], hasMore: true);

      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          feedCache: cache,
          initialTabIndex: 3,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                  throw StateError('offline'),
          searchLoader: (query, {int page = 1}) async =>
              throw StateError('offline'),
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await notifier.load();
      await _flushMicrotasks();
      final state = container.read(provider);
      expect(state.error, isNotNull);
      expect(state.items.map((item) => item.id), ['kept']);
    },
  );

  test(
    'a resumed cold start appends the fresh feed after the resume card',
    () async {
      HomeFeedCache.hiveReady = true;
      final cache = HomeFeedCache();
      await cache.save(
        videoTabIndex,
        [_item('old-1'), _item('last'), _item('old-3')],
        hasMore: true,
        lastVid: 'last',
      );

      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          feedCache: cache,
          initialTabIndex: videoTabIndex,
          resumeVideoFeed: true,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                  HomepagePage(
                    // 'last' reappears in the response: the seen set must
                    // deduplicate it (the client-side equivalent of the
                    // official filterIds request parameter).
                    items: [_item('fresh-1'), _item('last'), _item('fresh-2')],
                    nextOffset: 1,
                    sessionId: null,
                  ),
          searchLoader: (query, {int page = 1}) async => [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      final loading = notifier.load();

      // The visible list starts AT the resume card: earlier snapshot cards are
      // dropped, matching the official single-video landing cache.
      expect(container.read(provider).items.map((item) => item.id), [
        'last',
        'old-3',
      ]);

      await loading;
      // The fresh list is appended after the visible card, never replacing it —
      // the on-screen video must not flip to a different one.
      expect(container.read(provider).items.map((item) => item.id), [
        'last',
        'old-3',
        'fresh-1',
        'fresh-2',
      ]);
    },
  );

  test('a resume card already at index zero still appends instead of '
      'replacing', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      videoTabIndex,
      [_item('last'), _item('old-2')],
      hasMore: true,
      lastVid: 'last',
    );

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: videoTabIndex,
        resumeVideoFeed: true,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('fresh-1')],
                  nextOffset: 1,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await notifier.load();
    expect(container.read(provider).items.map((item) => item.id), [
      'last',
      'old-2',
      'fresh-1',
    ]);
  });

  test(
    'a resume point outside the snapshot falls back to wholesale replace',
    () async {
      HomeFeedCache.hiveReady = true;
      final cache = HomeFeedCache();
      await cache.save(
        videoTabIndex,
        [_item('a'), _item('b')],
        hasMore: true,
        lastVid: 'gone',
      );

      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          feedCache: cache,
          initialTabIndex: videoTabIndex,
          resumeVideoFeed: true,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                  HomepagePage(
                    items: [_item('fresh-1')],
                    nextOffset: 1,
                    sessionId: null,
                  ),
          searchLoader: (query, {int page = 1}) async => [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await notifier.load();
      expect(container.read(provider).items.map((item) => item.id), [
        'fresh-1',
      ]);
      HomeFeedSnapshot? saved;
      for (var i = 0; i < 80 && saved?.lastVid != 'fresh-1'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        saved = cache.load(videoTabIndex);
      }
      expect(saved?.lastVid, 'fresh-1');
    },
  );

  test('a manual refresh replaces the list instead of resuming', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      videoTabIndex,
      [_item('a'), _item('b')],
      hasMore: true,
      lastVid: 'b',
    );

    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: videoTabIndex,
        resumeVideoFeed: true,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('fresh-1')],
                  nextOffset: 1,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(provider.notifier);
    await notifier.load(manualRefresh: true);
    // Official Refresh path: the response replaces page one wholesale.
    expect(container.read(provider).items.map((item) => item.id), ['fresh-1']);
  });

  // The book grid has no visible-card reporter. Its saved first id is not a
  // video-style resume point, so page one must replace the snapshot wholesale.
  test('a book cold start replaces instead of video-resuming', () async {
    HomeFeedCache.hiveReady = true;
    final cache = HomeFeedCache();
    await cache.save(
      0,
      [_item('old-1', kind: 'book'), _item('last', kind: 'book')],
      hasMore: true,
      lastVid: 'last',
    );

    const rankCell = HomeCell(
      showType: 511,
      name: '新排行',
      id: 'fresh-rank',
      style: {'cover_size': 2},
      items: [],
      children: [
        HomeCell(
          showType: 512,
          name: '新书',
          id: 'fresh-rank-book',
          style: {},
          items: [],
          children: [],
        ),
      ],
      extra: {
        'rank_with_category_data': {'boards': 1},
      },
    );
    final provider = NotifierProvider<HomeNotifier, HomeState>(
      () => HomeNotifier(
        feedCache: cache,
        initialTabIndex: 0,
        homepageLoader:
            ({int tabType = 2, int offset = 0, String? sessionId}) async =>
                HomepagePage(
                  items: [_item('fresh-book', kind: 'book')],
                  cells: [rankCell],
                  nextOffset: null,
                  sessionId: null,
                ),
        searchLoader: (query, {int page = 1}) async => [],
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(provider.notifier).load();
    final state = container.read(provider);
    expect(state.items.map((item) => item.id), ['fresh-book']);
    expect(state.cells.map((cell) => cell.showType), [511]);
    expect(state.cells.single.name, '新排行');
    expect(state.cells.single.id, 'fresh-rank');
    expect(state.cells.single.extra['rank_with_category_data'], {'boards': 1});

    HomeFeedSnapshot? saved = cache.load(0);
    for (
      var i = 0;
      i < 80 &&
          (saved == null ||
              saved.items.length != 1 ||
              saved.items.first.id != 'fresh-book');
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      saved = cache.load(0);
    }
    expect(saved, isNotNull);
    expect(saved!.items.map((item) => item.id), ['fresh-book']);
    expect(saved.cells.single.showType, 511);
    expect(saved.lastVid, isNull);
    await cache.close();
  });

  test(
    'the position reported by the page is persisted as the resume point',
    () async {
      HomeFeedCache.hiveReady = true;
      final cache = HomeFeedCache();
      final requestedTabs = <int>[];
      final channelStarted = Completer<void>();
      final releaseChannel = Completer<void>();
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          feedCache: cache,
          initialTabIndex: videoTabIndex,
          usesLocalTabs: true,
          resumeVideoFeed: true,
          homepageLoader:
              ({int tabType = 2, int offset = 0, String? sessionId}) async {
                requestedTabs.add(tabType);
                if (tabType == 8) {
                  channelStarted.complete();
                  await releaseChannel.future;
                  return HomepagePage(
                    items: [_item('drama-1')],
                    nextOffset: 1,
                    sessionId: null,
                  );
                }
                return HomepagePage(
                  items: [_item('fresh-1'), _item('fresh-2')],
                  nextOffset: 1,
                  sessionId: null,
                );
              },
          searchLoader: (query, {int page = 1}) async => [],
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      await notifier.load();
      notifier.noteCurrentVid('fresh-2');
      // Switching to the first 看剧 grid completes another tab's initial load
      // before the two-second video-position debounce expires. That load must
      // not cancel the video tab's pending write.
      notifier.selectTab(dramaTabIndex);
      await channelStarted.future;
      releaseChannel.complete();
      await _flushMicrotasks();
      final dramaState = container.read(provider);
      expect(requestedTabs, [16, 8]);
      expect(dramaState.tabIndex, dramaTabIndex);
      expect(dramaState.isLoading, isFalse);
      expect(dramaState.items.map((item) => item.id), ['drama-1']);

      // The original video position eventually lands even though another tab
      // has since replaced itself and written its own snapshot.
      HomeFeedSnapshot? saved;
      for (var i = 0; i < 120 && saved?.lastVid != 'fresh-2'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        saved = cache.load(videoTabIndex);
      }
      expect(saved?.lastVid, 'fresh-2');
      await cache.close();
    },
  );
}
