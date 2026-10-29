import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/audio_extra.dart';
import 'package:fqapp/models/audio_time_track.dart';
import 'package:fqapp/services/listen_start_resolver.dart';

/// One paragraph point: the audio start of paragraph [para].
AudioTimeTrack _track(int para, int startMs) => AudioTimeTrack([
  AudioSyncPoint(
    startTime: startMs,
    startPara: para,
    startParaOff: 0,
    endPara: para,
    endParaOff: 10,
  ),
]);

const _paragraph = '前十八年，叶望川还以为自己只是普普通通穿越到了一个富人家。';

void main() {
  test('uses the tone that actually carries a mapping, not just tone 0', () async {
    // 智能朗读一本书有多个音色，时间轴按音色分开存：`0` 常常是空的，而候选表
    // 里的第二个音色才有数据。这正是「从本段听一律落章首」的根因。
    final asked = <String>[];
    final resolver = ListenStartResolver(
      bookId: 'b1',
      toneCandidatesLoader: (_) async => const ['', '7', '9'],
      timePointLoader: (itemId, toneId) async {
        asked.add(toneId);
        return toneId == '9' ? _track(2, 15400) : AudioTimeTrack.empty;
      },
    );

    final start = await resolver.resolve(
      itemId: 'c1',
      paragraphText: _paragraph,
      paraIndex: 2,
      ordinal: 2,
    );

    expect(start.startMs, 15400);
    expect(start.toneId, '9', reason: '播放页必须沿用命中的那个音色');
    expect(asked, ['0', '7', '9']);
  });

  test('tries the tone already in use first and asks few voices', () async {
    final asked = <String>[];
    final resolver = ListenStartResolver(
      bookId: 'b1',
      preferredToneId: '4',
      toneCandidatesLoader: (_) async => const ['5', '6', '7', '8'],
      timePointLoader: (itemId, toneId) async {
        asked.add(toneId);
        return _track(1, 6800);
      },
    );

    final start = await resolver.resolve(
      itemId: 'c1',
      paragraphText: _paragraph,
      paraIndex: 1,
      ordinal: 1,
    );

    expect(start.startMs, 6800);
    expect(asked.first, '4');
    // 一次定位最多问 ListenStartResolver.maxTones 个音色。
    expect(asked.length, lessThanOrEqualTo(ListenStartResolver.maxTones));
  });

  test('falls back to the subtitle track when no mapping exists', () async {
    final resolver = ListenStartResolver(
      bookId: 'b1',
      toneCandidatesLoader: (_) async => const [],
      timePointLoader: (itemId, toneId) async => AudioTimeTrack.empty,
      timelineLoader: (itemId, toneId) async => const SubtitleTrack([
        SubtitleCue(startMs: 900, text: '第一章'),
        SubtitleCue(startMs: 3200, text: '前十八年，叶望川还以为自己'),
      ]),
    );

    final start = await resolver.resolve(
      itemId: 'c1',
      paragraphText: _paragraph,
      paraIndex: null,
      ordinal: 0,
    );

    expect(start.startMs, 3200);
    expect(start.found, isTrue);
  });

  test('does not match a cue that only appears mid-paragraph', () async {
    // 字幕里的句子必须从段落开头对上；整段搜索会让「他说」这类常见句子把起播
    // 拽到几十秒之后。
    final resolver = ListenStartResolver(
      bookId: 'b1',
      toneCandidatesLoader: (_) async => const [],
      timePointLoader: (itemId, toneId) async => AudioTimeTrack.empty,
      timelineLoader: (itemId, toneId) async => const SubtitleTrack([
        SubtitleCue(startMs: 20000, text: '普普通通穿越到了一个富人家'),
      ]),
    );

    final start = await resolver.resolve(
      itemId: 'c1',
      paragraphText: _paragraph,
      paraIndex: null,
      ordinal: 0,
    );

    expect(start.startMs, isNull);
  });

  test('reports why it could not locate the paragraph', () async {
    final empty = ListenStartResolver(
      bookId: 'b1',
      toneCandidatesLoader: (_) async => const [],
      timePointLoader: (itemId, toneId) async => AudioTimeTrack.empty,
    );
    final noMapping = await empty.resolve(
      itemId: 'c1',
      paragraphText: _paragraph,
      paraIndex: 0,
      ordinal: 0,
    );
    expect(noMapping.note, '本章没有听书时间轴，只能从章首开始');

    // 有时间轴但段号对不上：两种情况的修法完全不同，文案必须分开。
    final mismatched = ListenStartResolver(
      bookId: 'b1',
      toneCandidatesLoader: (_) async => const [],
      timePointLoader: (itemId, toneId) async => _track(9, 40000),
    );
    final conflict = await mismatched.resolve(
      itemId: 'c1',
      paragraphText: '',
      paraIndex: 2,
      ordinal: 2,
    );
    expect(conflict.startMs, isNull);
    expect(conflict.note, contains('1 段'));
  });

  test('a failing loader never escapes', () async {
    final resolver = ListenStartResolver(
      bookId: 'b1',
      toneCandidatesLoader: (_) async => const [],
      timePointLoader: (itemId, toneId) async => throw Exception('boom'),
      timelineLoader: (itemId, toneId) async => throw Exception('boom'),
    );

    final start = await resolver.resolve(
      itemId: 'c1',
      paragraphText: _paragraph,
      paraIndex: 0,
      ordinal: 0,
    );

    expect(start.startMs, isNull);
    expect(start.note, isNotNull);
  });
}
