import '../models/audio_extra.dart';
import '../models/audio_time_track.dart';
import 'api_client.dart';
import 'audio_time_point_lookup.dart';

/// `/timepoints` 加载器：正文章节 id + 音色 → 「音频毫秒 ↔ 段落」映射。
typedef TimePointsLoader =
    Future<AudioTimeTrack> Function(String itemId, String toneId);

/// `/timeline` 加载器：正文章节 id + 音色 → 逐句字幕轨。
typedef TimelineLoader =
    Future<SubtitleTrack> Function(String itemId, String toneId);

/// 音色候选加载器：书 id → 可尝试的音色 id 列表（按优先级）。
typedef ToneCandidatesLoader = Future<List<String>> Function(String bookId);

/// 一次「从本段/从本页」定位的结果。
class ListenStart {
  const ListenStart(this.startMs, {this.toneId, this.note});

  /// 起播毫秒；null 表示没定位到，调用方落回章首。
  final int? startMs;

  /// 命中的音色。播放页必须用同一个音色，否则会 seek 到另一条录音的同一毫秒。
  final String? toneId;

  /// 没定位到时的原因，直接展示给用户。
  ///
  /// 静默兜底会让「点了没反应」无法区分是这本书没有时间轴，还是我们没对上
  /// 段落——两种情况要修的地方完全不同。
  final String? note;

  bool get found => startMs != null;
}

/// 把「正文某一段」落成智能朗读的起播毫秒。
///
/// 三条来源，从准到粗：
///
///  1. 章节正文自带的 `<span start_time>` —— 阅读页先查，最准，不经过这里；
///  2. `/timepoints`：听书高亮用的「音频毫秒 ↔ 段落」映射。
///  3. `/timeline`：边听边读字幕轨（每句的起始毫秒）。没有段落映射但有字幕的
///     书走这条：用段落开头几个字去字幕里顺序匹配。
///
/// 第 2 条**按音色分开存**：问错 `tone_id` 只会拿到空表，看起来就像「这本书没
/// 时间轴」。智能朗读一本书有 7 个音色，而客户端默认的 `0` 未必在其中，所以要
/// 按候选音色逐个试。音色之间共用同一条时间轴（切换音色时能从断处续播），所以
/// 任一候选命中即可。
///
/// 三条都没命中时返回 null，调用方落回章首——错位起播比从章首播更糟。
class ListenStartResolver {
  ListenStartResolver({
    required this.bookId,
    this.preferredToneId,
    this.timePointLoader,
    this.timelineLoader,
    this.toneCandidatesLoader,
  });

  final String bookId;

  /// 当前正在听的音色，排候选第一位（命中率最高，也省一次请求）。
  final String? preferredToneId;

  /// 测试注入口；省略时走 [ApiClient]。
  final TimePointsLoader? timePointLoader;
  final TimelineLoader? timelineLoader;
  final ToneCandidatesLoader? toneCandidatesLoader;

  /// 最多试几个音色。每个都是一次网络请求，试太多会把「正在获取本段音频…」
  /// 拖成好几秒。
  static const int maxTones = 4;

  /// 字幕匹配至少要重合几个字：太短会在正文里撞上「他说」这种常见开头。
  static const int minCueChars = 5;

  /// 定位 [paragraphText] 这一段的起播毫秒。
  ///
  /// [paraIndex] 是上游 `<p idx>` 段号（纯文本章节为 null），[ordinal] 是它在
  /// 正文里的段序（标题不计入，从 0 起）。
  Future<ListenStart> resolve({
    required String itemId,
    required String paragraphText,
    int? paraIndex,
    required int ordinal,
  }) async {
    final tried = <String>[];
    var pointsSeen = 0;

    Future<ListenStart?> attempt(List<String> tones) async {
      for (final tone in tones) {
        if (tried.length >= maxTones) break;
        if (tone.isEmpty || tried.contains(tone)) continue;
        tried.add(tone);
        final track = await _timePoints(itemId, tone);
        if (track.isEmpty) continue;
        if (track.points.length > pointsSeen) pointsSeen = track.points.length;
        final startMs = startMsForParagraph(
          track,
          paraIndex: paraIndex,
          ordinal: ordinal,
        );
        if (startMs != null) return ListenStart(startMs, toneId: tone);
      }
      return null;
    }

    // 第一轮只用手上已知的音色，省掉一次音色表请求：绝大多数书第一步就命中。
    var hit = await attempt([
      if (preferredToneId != null) preferredToneId!,
      '0',
    ]);
    // 第二轮才查音色表：时间轴按音色分开存，而默认音色常常是空的。
    hit ??= await attempt(await _moreTones());
    if (hit != null) return hit;

    if (paragraphText.isNotEmpty) {
      for (final tone in tried) {
        final track = await _timeline(itemId, tone);
        if (track.isEmpty) continue;
        final startMs = startMsForCue(track, paragraphText);
        if (startMs != null) return ListenStart(startMs, toneId: tone);
      }
    }
    return ListenStart(
      null,
      note: pointsSeen == 0
          ? '本章没有听书时间轴，只能从章首开始'
          : '时间轴有 $pointsSeen 段但没对上本段，只能从章首开始',
    );
  }

  /// 音色表里的其它候选（智能朗读、离线音色、真人讲书）。
  Future<List<String>> _moreTones() async {
    final loader = toneCandidatesLoader;
    if (loader != null) return loader(bookId);
    return _tonesFromApi();
  }

  /// 从 `/tones` 收集音色 id：官方推荐的那个优先，然后智能朗读、离线音色、
  /// 真人讲书。音色表只是候选来源，拿不到就只试已排在前面的音色。
  Future<List<String>> _tonesFromApi() async {
    try {
      final tones = await ApiClient.instance
          .bookTones(bookId)
          .timeout(const Duration(seconds: 6));
      return [
        if (tones.recommended?.id != null) tones.recommended!.id,
        for (final tone in tones.ttsTones) tone.id,
        for (final tone in tones.offlineTones) tone.id,
        for (final tone in tones.narratorTones) tone.id,
      ];
    } on Exception {
      return const [];
    }
  }

  Future<AudioTimeTrack> _timePoints(String itemId, String tone) async {
    try {
      final loader = timePointLoader;
      if (loader != null) return await loader(itemId, tone);
      return await ApiClient.instance.chapterTimePoints(
        bookId,
        itemId,
        toneId: tone,
      );
    } on Exception {
      return AudioTimeTrack.empty;
    }
  }

  Future<SubtitleTrack> _timeline(String itemId, String tone) async {
    try {
      final loader = timelineLoader;
      if (loader != null) return await loader(itemId, tone);
      return await ApiClient.instance.chapterTimeline(itemId, toneId: tone);
    } on Exception {
      return SubtitleTrack.empty;
    }
  }
}

/// 字幕与正文之间可以忽略的字符：标点与空白。
///
/// 两边常在全/半角、省略号写法上不一致，剥掉再比（与 `CueIndex.cueNoise` 同
/// 一套口径，免得同一本书在两处得到不同结论）。
final RegExp _cueNoise = RegExp(
  r'[\s，。！？；：、“”‘’（）《》〈〉…—·,.!?;:"()\[\]{}]',
);

String _normalize(String raw) => raw.replaceAll(_cueNoise, '');

/// 用段落文本去字幕轨里找这一段的起始毫秒。
///
/// 字幕是按句切的，段落通常从一个句子开头起读，所以拿段落开头几个字做**前
/// 缀**匹配即可。整段搜索是不行的：后面某句完全可能先匹配到前面出现过的相同
/// 片段，一旦错位，起播就落到别处（`CueIndex` 用顺序游标解决同一问题）。
int? startMsForCue(SubtitleTrack track, String paragraphText) {
  if (track.isEmpty) return null;
  final target = _normalize(paragraphText);
  if (target.isEmpty) return null;
  for (final cue in track.cues) {
    final text = _normalize(cue.text);
    if (text.length < ListenStartResolver.minCueChars) continue;
    if (target.startsWith(text)) return cue.startMs;
  }
  // 首句被切成两半、或数字/生僻字读法不同时，退一步比公共前缀。
  for (final cue in track.cues) {
    final text = _normalize(cue.text);
    if (text.length < ListenStartResolver.minCueChars) continue;
    if (_commonPrefix(target, text) >= ListenStartResolver.minCueChars) {
      return cue.startMs;
    }
  }
  return null;
}

int _commonPrefix(String a, String b) {
  final limit = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}
