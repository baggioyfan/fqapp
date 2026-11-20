import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/channel_tab.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/rank.dart';
import 'package:fqapp/pages/comic_reader_page.dart';
import 'package:fqapp/pages/drama_page.dart';
import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/pages/mine_page.dart';
import 'package:fqapp/pages/rank_page.dart';
import 'package:fqapp/pages/settings_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/app_theme_style.dart';
import 'package:fqapp/services/desktop_platform.dart';
import 'package:fqapp/services/drama_channel_preferences.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';
import 'package:fqapp/widgets/desktop_chapter_sidebar.dart';
import 'package:fqapp/widgets/desktop_settings_body.dart';
import 'package:fqapp/widgets/desktop_shell_scope.dart';
import 'package:fqapp/widgets/home/home_back_button.dart';
import 'package:fqapp/widgets/wenku/wenku_ui.dart';
import 'support/app_ui_host.dart';
import 'support/controlled_player.dart';
import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    desktopTab.value = 0;
    DesktopPlatform.fullscreen.value = false;
    DesktopPlatform.maximized.value = false;
    DesktopShellState.reset();
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.light;
    AppThemeStyleStore.instance.value = AppThemeStyle.archive;
  });

  tearDown(() {
    desktopTab.value = 0;
    DesktopPlatform.fullscreen.value = false;
    DesktopPlatform.maximized.value = false;
    DesktopShellState.reset();
    einkModeNotifier.value = false;
    oledModeNotifier.value = false;
    themeModeNotifier.value = ThemeMode.system;
    AppThemeStyleStore.instance.value = AppThemeStyle.archive;
  });

  testWidgets('HomePage inside DesktopAppFrame omits duplicate masthead', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(
              () => HomeNotifier(
                homepageLoader:
                    ({
                      int tabType = 2,
                      int offset = 0,
                      String? sessionId,
                    }) async => const HomepagePage(
                      items: [],
                      nextOffset: null,
                      sessionId: null,
                    ),
                searchLoader: (query, {int page = 1}) async => const [],
              ),
            ),
          ],
          child: const MaterialApp(home: DesktopAppFrame(child: HomePage())),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home_search_button')), findsNothing);
      expect(find.byKey(const Key('home_category_button')), findsOneWidget);
      expect(find.text('什锦铺'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.binding.setSurfaceSize(null);
      DesktopShellState.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'Windows SettingsPage renders DesktopSettingsBody without outer WenkuPage',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      try {
        await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(DesktopSettingsBody), findsOneWidget);
        expect(
          find.ancestor(
            of: find.byType(DesktopSettingsBody),
            matching: find.byType(WenkuPage),
          ),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.binding.setSurfaceSize(null);
        DesktopShellState.reset();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('DesktopChapterSidebar applies custom colors and collapses', (
    tester,
  ) async {
    var collapsed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopChapterSidebar(
            backgroundColor: const Color(0xFFF3E4C2),
            textColor: const Color(0xFF493D2B),
            chapters: [
              for (var i = 0; i < 4; i++)
                Chapter(itemId: '$i', title: '第 $i 章', volumeName: ''),
            ],
            currentIndex: 1,
            onCollapse: () => collapsed = true,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('收起目录'));
    await tester.pump();
    expect(collapsed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Windows MinePage renders two-column layout in archive and classic',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      final store = AppThemeStyleStore();
      try {
        for (final style in [AppThemeStyle.archive, AppThemeStyle.classic]) {
          store.value = style;
          await tester.pumpWidget(
            AppUiHost(
              store: store,
              home: const DesktopAppFrame(child: MinePage()),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('windows-mine-two-column')),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        store.dispose();
        await tester.binding.setSurfaceSize(null);
        DesktopShellState.reset();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'Windows RankPage inside DesktopAppFrame omits back button and uses 2-col grid',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: DesktopAppFrame(
              child: RankPage(
                catalogLoader: () async => const RankCatalog(
                  rankId: '1',
                  tabs: [RankTab(name: '推荐榜', algo: 101)],
                  categories: [RankCategory(name: '全部', id: 0)],
                ),
                pageLoader:
                    ({
                      required rankId,
                      required algo,
                      required categoryId,
                      required offset,
                      required startAt,
                    }) async => const RankBoard(
                      entries: [
                        RankEntry(
                          position: 1,
                          id: '1',
                          title: '作品一',
                          author: '甲',
                        ),
                        RankEntry(
                          position: 2,
                          id: '2',
                          title: '作品二',
                          author: '乙',
                        ),
                      ],
                      hasMore: false,
                    ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(HomeBackButton), findsNothing);
        expect(find.byKey(const Key('rank_list')), findsOneWidget);
        final sliverGrid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        final delegate =
            sliverGrid.gridDelegate
                as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, 2);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.binding.setSurfaceSize(null);
        DesktopShellState.reset();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('ComicReaderPage sidebar collapses and expands on Windows', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ComicReaderPage(
            bookId: 'comic-1',
            title: '测试漫画',
            startIndex: 0,
            readerStore: MemoryReaderStore(),
            cache: MemoryChapterCache(),
            chapterLoader: (_) async => const <ComicImage>[],
            chapters: [
              Chapter(itemId: 'c1', title: '第1话', volumeName: ''),
              Chapter(itemId: 'c2', title: '第2话', volumeName: ''),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DesktopChapterSidebar), findsOneWidget);
      await tester.tap(find.byTooltip('收起目录'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopChapterSidebar), findsNothing);
      expect(
        find.byKey(const Key('comic-desktop-sidebar-toggle')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('comic-desktop-sidebar-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopChapterSidebar), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.binding.setSurfaceSize(null);
      DesktopShellState.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows DramaPage browse grid auto-fills beyond 6 items', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    DramaChannelPreferences.reset();
    DramaChannelPreferences.load(await SharedPreferences.getInstance());
    final requestedOffsets = <int>[];

    HomeNotifier makeNotifier({int initialTabIndex = 0}) => HomeNotifier(
      initialTabIndex: initialTabIndex,
      homepageLoader:
          ({int tabType = 2, int offset = 0, String? sessionId}) async {
            if (tabType == kChannelVideoEpisode) {
              requestedOffsets.add(offset);
              const pageSize = 6;
              final items = [
                for (var i = 0; i < pageSize; i++)
                  MediaItem(
                    id: 'ep-${offset + i}',
                    title: '短剧 ${offset + i}',
                    cover: '',
                    author: '演员',
                    badge: '',
                    ep: '全20集',
                    kind: 'video',
                  ),
              ];
              return HomepagePage(
                items: items,
                nextOffset: offset + pageSize < 24 ? offset + pageSize : null,
                sessionId: 'sess-1',
              );
            }
            return HomepagePage(
              items: [
                MediaItem(
                  id: 'feed-1',
                  title: '推荐剧 1',
                  cover: '',
                  author: '演员',
                  badge: '',
                  ep: '全12集',
                  kind: 'video',
                ),
              ],
              nextOffset: null,
              sessionId: null,
            );
          },
      searchLoader: (query, {int page = 1}) async => const [],
    );

    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            homeProvider.overrideWith(() => makeNotifier()),
            dramaProvider.overrideWith(
              () => makeNotifier(initialTabIndex: dramaTabIndex),
            ),
          ],
          child: MaterialApp(
            home: DramaPage(
              channelLoader: () async => const ChannelTable(
                tabs: [
                  ChannelTab(type: kChannelVideoFeed, title: '推荐'),
                  ChannelTab(type: kChannelVideoEpisode, title: '看剧'),
                ],
              ),
              contentLoader: (itemId, tab) async =>
                  throw const ApiException('offline test'),
              historyStore: ControlledReaderStore(),
              playerFactory: () => ControlledNativePlayer(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('看剧'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('drama_episode_grid')), findsOneWidget);
      expect(requestedOffsets, containsAll(<int>[0, 6]));
      expect(find.text('短剧 0'), findsOneWidget);
      expect(find.text('短剧 6'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      DramaChannelPreferences.reset();
      await tester.binding.setSurfaceSize(null);
      DesktopShellState.reset();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
