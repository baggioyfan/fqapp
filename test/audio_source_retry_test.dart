import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/models/chapter_media.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/audio_page.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/audio_preferences.dart';
import 'package:fqapp/services/listening_session.dart';
import 'package:fqapp/services/native_player.dart';

import 'support/controlled_player.dart';

/// 音源路由收到的每一次请求。
final _sourceRequests = <Uri>[];

/// 本次测试的音源应答；其他路由由 [_handle] 兜底。
Future<http.Response> Function(http.Request request) _sourceResponse =
    (_) async => http.Response('{}', 404);

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<http.Response> _handle(http.Request request) {
  final path = request.url.path;
  if (path.contains('/audio/books/') && path.contains('/chapters/')) {
    _sourceRequests.add(request.url);
    return _sourceResponse(request);
  }
  return Future.value(_json({'code': 0, 'data': <String, Object>{}}, 200));
}

void _mockIosAudioSessionEvents() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('fqapp/audio_session/events'),
    (_) async => null,
  );
  addTearDown(
    () => messenger.setMockMethodCallHandler(
      const MethodChannel('fqapp/audio_session/events'),
      null,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // 听书页默认走 ApiClient.instance；在 mock 客户端所在的 Zone 里先把它
    // 建出来，之后所有请求都经过 _handle。
    http.runWithClient(() => ApiClient.instance, () => MockClient(_handle));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AudioPreferences.instance.resetForTest();
    ListeningSession.instance.clear();
    _sourceRequests.clear();
    _sourceResponse = (_) async => http.Response('{}', 404);
  });

  testWidgets('a 404 audio source fails after one request, not three', (
    tester,
  ) async {
    _sourceResponse = (_) async => _json({'error': '章节不存在'}, 404);

    await _mount(tester);
    await _pumpUntil(tester, () => tester.any(find.text('播放出错，请稍后重试')));

    expect(find.text('播放出错，请稍后重试'), findsOneWidget);
    expect(_sourceRequests, hasLength(1), reason: '404 再试也是同一个结果');
  });

  testWidgets('the NO_THIS_TONE fallback uses the same fail-fast policy', (
    tester,
  ) async {
    _sourceResponse = (request) async {
      // tone 0 是这本纯 TTS 书没有的默认音色；换用音色 1 时给 404。
      final tone = request.url.queryParameters['tone_id'];
      if (tone == '0') {
        return _json({'code': 101000, 'message': 'NO_THIS_TONE'}, 200);
      }
      return _json({'error': '章节不存在'}, 404);
    };

    await _mount(tester);
    await _pumpUntil(tester, () => tester.any(find.text('播放出错，请稍后重试')));

    expect(_sourceRequests.map((url) => url.queryParameters['tone_id']), [
      '0',
      '1',
    ], reason: '回退音色的 404 也只请求一次');
  });

  testWidgets('saved preferred voice is requested before automatic fallback', (
    tester,
  ) async {
    await AudioPreferences.instance.setDefaultVoice(
      DefaultListeningVoice.matureClassic,
    );
    _sourceResponse = (request) async {
      final tone = request.url.queryParameters['tone_id'];
      if (tone == '64') {
        return _json({'code': 101000, 'message': 'NO_THIS_TONE'}, 200);
      }
      return _json(_playinfoPayload('1'), 200);
    };
    final players = <ControlledNativePlayer>[];
    await _mount(
      tester,
      players: players,
      extras: const AudioExtras(
        tones: AudioToneSet(
          ttsTones: [
            AudioTone(id: '96', title: '多角色对话升级版'),
            AudioTone(id: '64', title: '成熟大叔'),
          ],
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => players.isNotEmpty && players.single.isPlaying,
    );
    expect(_sourceRequests.map((url) => url.queryParameters['tone_id']), [
      '64',
      '96',
    ]);
  });

  testWidgets('the next chapter buffers and falls back before auto-advance', (
    tester,
  ) async {
    final players = <ControlledNativePlayer>[];
    _sourceResponse = (request) async {
      final item = request.url.pathSegments.last;
      final tone = request.url.queryParameters['tone_id'];
      if (item == '2' && tone != '64') {
        return _json({'code': 101000, 'message': 'NO_THIS_TONE'}, 200);
      }
      return _json(
        _playinfoPayload(item, url: 'https://cdn.example/$item-$tone.m4a'),
        200,
      );
    };
    await _mount(
      tester,
      players: players,
      chapters: [
        Chapter(itemId: '1', title: '第1章', volumeName: ''),
        Chapter(itemId: '2', title: '第2章', volumeName: ''),
      ],
      extras: const AudioExtras(
        tones: AudioToneSet(
          ttsTones: [
            AudioTone(id: '64', title: '成熟大叔音'),
            AudioTone(id: '74', title: '成熟大叔音升级版'),
            AudioTone(id: '57', title: '多角色对话'),
            AudioTone(id: '96', title: '多角色对话升级版'),
          ],
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => players.isNotEmpty && players.first.isPlaying,
    );
    players.first.emitPosition(const Duration(seconds: 2));
    await _pumpUntil(
      tester,
      () => players.length == 2 && players.last.isCreated,
    );
    expect(players.first.isPlaying, isTrue);
    expect(players.last.isPlaying, isFalse);
    expect(_sourceRequests.map((url) => url.queryParameters['tone_id']), [
      '96',
      '96',
      '57',
      '74',
      '64',
    ]);
    players.first.emitCompleted();
    await tester.pump();
    await _pumpUntil(tester, () => players.last.isPlaying);
    expect(players, hasLength(2));
    expect(players.first.disposed, isTrue);
    expect(players.last.calls.where((call) => call.startsWith('create:')), [
      'create:https://cdn.example/2-64.m4a',
    ]);
    expect(_sourceRequests, hasLength(5));
  });

  testWidgets('iOS background defers next-chapter prefetch until foreground', (
    tester,
  ) async {
    _mockIosAudioSessionEvents();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final players = <ControlledNativePlayer>[];
    _sourceResponse = (request) async {
      final item = request.url.pathSegments.last;
      final tone = request.url.queryParameters['tone_id'];
      return _json(
        _playinfoPayload(item, url: 'https://cdn.example/$item-$tone.m4a'),
        200,
      );
    };
    await _mount(
      tester,
      players: players,
      chapters: [
        Chapter(itemId: '1', title: '第1章', volumeName: ''),
        Chapter(itemId: '2', title: '第2章', volumeName: ''),
      ],
    );
    await _pumpUntil(
      tester,
      () => players.isNotEmpty && players.first.isPlaying,
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flush(tester);
    players.first.emitPosition(const Duration(seconds: 2));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(players.first.isPlaying, isTrue);
    expect(_sourceRequests, isNotEmpty);
    expect(players, hasLength(1), reason: 'iOS 后台不能新建 media_kit 播放器');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flush(tester);
    players.first.emitPosition(const Duration(seconds: 3));
    await _pumpUntil(
      tester,
      () => players.length == 2 && players.last.isCreated,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('iOS background during prefetch source wait allocates nothing', (
    tester,
  ) async {
    _mockIosAudioSessionEvents();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final players = <ControlledNativePlayer>[];
    final nextSource = Completer<http.Response>();
    _sourceResponse = (request) async {
      final item = request.url.pathSegments.last;
      final tone = request.url.queryParameters['tone_id'];
      if (item == '2') return nextSource.future;
      return _json(
        _playinfoPayload(item, url: 'https://cdn.example/$item-$tone.m4a'),
        200,
      );
    };
    await _mount(
      tester,
      players: players,
      chapters: [
        Chapter(itemId: '1', title: '第1章', volumeName: ''),
        Chapter(itemId: '2', title: '第2章', volumeName: ''),
      ],
    );
    await _pumpUntil(
      tester,
      () => players.isNotEmpty && players.first.isPlaying,
    );
    players.first.emitPosition(const Duration(seconds: 2));
    await _pumpUntil(
      tester,
      () => _sourceRequests.any((url) => url.pathSegments.last == '2'),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flush(tester);
    nextSource.complete(
      _json(_playinfoPayload('2', url: 'https://cdn.example/2-0.m4a'), 200),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(players, hasLength(1), reason: '退到后台后不再新建播放器');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flush(tester);
    players.first.emitPosition(const Duration(seconds: 3));
    await _pumpUntil(
      tester,
      () => players.length == 2 && players.last.isCreated,
    );
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('late voice metadata replaces the prebuffered default tone', (
    tester,
  ) async {
    final players = <ControlledNativePlayer>[];
    final extras = Completer<AudioExtras>();
    _sourceResponse = (request) async {
      final item = request.url.pathSegments.last;
      final tone = request.url.queryParameters['tone_id'];
      return _json(
        _playinfoPayload(item, url: 'https://cdn.example/$item-$tone.m4a'),
        200,
      );
    };
    await _mount(
      tester,
      players: players,
      extrasLoader: (_) => extras.future,
      chapters: [
        Chapter(itemId: '1', title: '第1章', volumeName: ''),
        Chapter(itemId: '2', title: '第2章', volumeName: ''),
      ],
    );
    await _pumpUntil(
      tester,
      () => players.isNotEmpty && players.first.isPlaying,
    );
    players.first.emitPosition(const Duration(seconds: 2));
    await _pumpUntil(
      tester,
      () => players.length == 2 && players.last.isCreated,
    );
    extras.complete(
      const AudioExtras(
        tones: AudioToneSet(
          ttsTones: [AudioTone(id: '96', title: '多角色对话升级版')],
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          players.any(
            (player) =>
                player.isPlaying &&
                player.calls.contains('create:https://cdn.example/1-96.m4a'),
          ) &&
          players.any(
            (player) =>
                player.isCreated &&
                player.calls.contains('create:https://cdn.example/2-96.m4a'),
          ),
    );
    final current = players.singleWhere((player) => player.isPlaying);
    expect(players[1].disposed, isTrue);
    expect(players.first.disposed, isTrue);
    expect(current.position, const Duration(seconds: 2));
    current.emitCompleted();
    await _pumpUntil(
      tester,
      () => players.any(
        (player) =>
            player.isPlaying &&
            player.calls.contains('create:https://cdn.example/2-96.m4a'),
      ),
    );
    expect(
      _sourceRequests.map(
        (url) => '${url.pathSegments.last}:${url.queryParameters['tone_id']}',
      ),
      unorderedEquals(['1:0', '2:0', '1:96', '2:96']),
    );
  });

  testWidgets('a 5xx audio source is retried and then plays', (tester) async {
    final sourceAttempts = <String, int>{};
    final timePointAttempts = <String, int>{};
    final subtitleAttempts = <String, int>{};
    _sourceResponse = (request) async {
      final itemId = request.url.pathSegments.last;
      final attempt = (sourceAttempts[itemId] ?? 0) + 1;
      sourceAttempts[itemId] = attempt;
      if (itemId == '1' && attempt == 1) {
        return _json({'error': '服务暂不可用'}, 503);
      }
      return _json(
        _playinfoPayload(
          itemId,
          url: 'https://cdn.example/$itemId-$attempt.m4a',
        ),
        200,
      );
    };

    final players = <ControlledNativePlayer>[];
    await _mount(
      tester,
      players: players,
      chapters: [
        Chapter(itemId: '1', title: '第1章', volumeName: ''),
        Chapter(itemId: '2', title: '第2章', volumeName: ''),
        Chapter(itemId: '3', title: '第3章', volumeName: ''),
      ],
      subtitleLoader: (itemId, _) async {
        final attempt = (subtitleAttempts[itemId] ?? 0) + 1;
        subtitleAttempts[itemId] = attempt;
        if (itemId != '3' && attempt <= 3) {
          throw const ApiException('temporary', statusCode: 503);
        }
        if (itemId != '1') return SubtitleTrack.empty;
        return const SubtitleTrack([
          SubtitleCue(startMs: 0, text: '恢复后的服务端字幕'),
        ]);
      },
      timePointLoader: (itemId, _) async {
        final attempt = (timePointAttempts[itemId] ?? 0) + 1;
        timePointAttempts[itemId] = attempt;
        if (itemId == '2') {
          throw const ApiException('temporary', statusCode: 503);
        }
        if (itemId == '3') return AudioTimeTrack.empty;
        if (attempt <= 3) {
          throw const ApiException('temporary', statusCode: 503);
        }
        return const AudioTimeTrack([
          AudioSyncPoint(
            startTime: 0,
            startPara: 0,
            startParaOff: 0,
            endPara: 0,
            endParaOff: 1,
          ),
        ], novelItemId: 'novel-1');
      },
    );
    await _pumpUntil(
      tester,
      () =>
          players.isNotEmpty &&
          players.single.isPlaying &&
          timePointAttempts['1'] == 3 &&
          subtitleAttempts['1'] == 3,
      settleMs: 700,
    );

    expect(sourceAttempts['1'], 2, reason: '5xx 值得再取一次');
    expect(players, isNotEmpty);
    expect(players.single.isPlaying, isTrue);
    expect(ListeningSession.instance.novelChapterId, isNull);

    // 初次 3 次都用完后，用户关闭跟随；30 秒后的同章恢复既不能重新打开
    // followArmed，也不能把字幕 fallback 当成时间点已经终态。
    ListeningSession.instance.setFollowArmed(false);
    await tester.pump(const Duration(seconds: 30));
    await _flush(tester);

    expect(timePointAttempts['1'], 4, reason: '同章在低频恢复探测中成功');
    expect(subtitleAttempts['1'], 4, reason: '字幕轨也由同一次恢复探测补齐');
    expect(ListeningSession.instance.novelChapterId, 'novel-1');
    expect(ListeningSession.instance.subtitles?.cues.single.text, '恢复后的服务端字幕');
    expect(ListeningSession.instance.followArmed, isFalse);

    // CDN failure after a successful model fetch must not reuse that model
    // on a manual retry. Preserve the listener's position and selected voice.
    players.single.emitPosition(const Duration(seconds: 23));
    players.single.errors.add(
      const NativePlaybackException(
        'Playback failed',
        errorCode: 2004,
        httpStatusCode: 403,
      ),
    );
    await _flush(tester);
    expect(find.text('播放出错，请稍后重试'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('audio-retry')));
    await tester.tap(find.byKey(const ValueKey('audio-retry')));
    await _pumpUntil(
      tester,
      () =>
          players.length == 2 &&
          players.last.isPlaying &&
          timePointAttempts['1'] == 5 &&
          subtitleAttempts['1'] == 5,
      settleMs: 700,
    );
    expect(sourceAttempts['1'], 3, reason: '手动重试重新获取模型');
    expect(players.last.calls, contains('create:https://cdn.example/1-3.m4a'));
    expect(players.last.position, const Duration(seconds: 23));
    expect(
      _sourceRequests
          .where((uri) => uri.pathSegments.last == '1')
          .map((uri) => uri.queryParameters['tone_id']),
      ['0', '0', '0'],
    );

    // 用户关闭跟随后，已成功的轨道不应再排恢复请求或重新打开跟随。
    ListeningSession.instance.setFollowArmed(false);
    await tester.pump(const Duration(seconds: 30));
    await _flush(tester);

    expect(timePointAttempts['1'], 5, reason: '重试后取得有效时间轴，不再重复恢复');
    expect(subtitleAttempts['1'], 5, reason: '重试后取得有效字幕，不再重复恢复');
    expect(ListeningSession.instance.novelChapterId, 'novel-1');
    expect(ListeningSession.instance.subtitles?.cues.single.text, '恢复后的服务端字幕');
    expect(ListeningSession.instance.followArmed, isFalse);

    // 第 2 章再次耗尽后立刻换章；旧章的恢复 timer/request 必须一起失效。
    await tester.ensureVisible(find.byTooltip('下一章'));
    await tester.tap(find.byTooltip('下一章'));
    await _flush(tester);
    await _pumpUntil(
      tester,
      () => timePointAttempts['2'] == 3 && subtitleAttempts['2'] == 3,
      settleMs: 700,
    );
    expect(ListeningSession.instance.chapterId, '2');

    // 暂停时连已排好的恢复 timer 也要撤掉；续播同章才按新的 30 秒窗口
    // 重新探测，且只探一次。
    final secondPlayer = players.last;
    await tester.ensureVisible(find.byTooltip('暂停'));
    await tester.tap(find.byTooltip('暂停'));
    await _flush(tester);
    expect(secondPlayer.isPlaying, isFalse);
    await tester.pump(const Duration(seconds: 31));
    await _flush(tester);
    expect(timePointAttempts['2'], 3);
    expect(subtitleAttempts['2'], 3);

    await tester.ensureVisible(find.byTooltip('播放'));
    await tester.tap(find.byTooltip('播放'));
    await _flush(tester);
    expect(secondPlayer.isPlaying, isTrue);
    await tester.pump(const Duration(seconds: 29));
    await _flush(tester);
    expect(timePointAttempts['2'], 3);
    await tester.pump(const Duration(seconds: 1));
    await _flush(tester);
    expect(timePointAttempts['2'], 4);
    expect(subtitleAttempts['2'], 4);

    // 恢复探测再次失败后又排了下一轮；此时换章，旧章不得再发第 5 次请求。
    await tester.ensureVisible(find.byTooltip('下一章'));
    await tester.tap(find.byTooltip('下一章'));
    await _flush(tester);
    await _pumpUntil(
      tester,
      () => ListeningSession.instance.chapterId == '3',
      settleMs: 700,
    );
    await tester.pump(const Duration(seconds: 31));
    await _flush(tester);

    expect(timePointAttempts['2'], 4);
    expect(subtitleAttempts['2'], 4);
    expect(timePointAttempts['3'], 1, reason: '合法空时间轴是终态，不进入周期恢复');
    expect(subtitleAttempts['3'], 1, reason: '合法空字幕也是终态，不进入周期恢复');
  });
}

Map<String, dynamic> _playinfoPayload(
  String itemId, {
  String url = 'https://cdn.example/1.m4a',
}) => {
  'code': 0,
  'data': [
    {
      'main_url': url,
      'item_id': itemId,
      'indate': 86400,
      'video_model': jsonEncode({
        'status': 10,
        'media_type': 'audio',
        'video_duration': 42.0,
        'video_list': [
          {'main_url': url},
        ],
      }),
    },
  ],
};

Widget _app(
  List<ControlledNativePlayer> players, {
  List<Chapter>? chapters,
  AudioExtras extras = const AudioExtras(),
  AudioExtrasLoader? extrasLoader,
  SubtitleLoader? subtitleLoader,
  TimePointLoader? timePointLoader,
}) => MaterialApp(
  home: AudioPage(
    bookId: 'book',
    title: '测试听书',
    chapters: chapters ?? [Chapter(itemId: '1', title: '第1章', volumeName: '')],
    historyStore: ControlledReaderStore(),
    voicesLoader: () async => const [AudioVoice(id: '1', label: '音色一')],
    extrasLoader: extrasLoader ?? (_) async => extras,
    subtitleLoader: subtitleLoader ?? (_, _) async => SubtitleTrack.empty,
    timePointLoader: timePointLoader ?? (_, _) async => AudioTimeTrack.empty,
    excerptLoader: (_) async => null,
    directoryLoader: (_) async => const [],
    playerFactory: () {
      final player = ControlledNativePlayer();
      players.add(player);
      return player;
    },
  ),
);

Future<void> _mount(
  WidgetTester tester, {
  List<ControlledNativePlayer>? players,
  List<Chapter>? chapters,
  AudioExtras extras = const AudioExtras(),
  AudioExtrasLoader? extrasLoader,
  SubtitleLoader? subtitleLoader,
  TimePointLoader? timePointLoader,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    _app(
      players ?? [],
      chapters: chapters,
      extras: extras,
      extrasLoader: extrasLoader,
      subtitleLoader: subtitleLoader,
      timePointLoader: timePointLoader,
    ),
  );
  await _flush(tester);
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 等真实 isolate / 网络回调与重试退避都跑完，直到 [done] 成立。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int settleMs = 16,
}) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(Duration(milliseconds: settleMs));
  }
  expect(done(), isTrue);
}
