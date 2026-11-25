import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';

import '../../services/desktop_platform.dart';
import '../../services/native_player.dart';
import '../../services/player_load_diagnostics.dart';

/// Compact, live playback diagnostics for the shared mobile and desktop
/// player chrome.
///
/// This widget is deliberately mounted only while the user has the stats panel
/// open. It owns the polling loop so every chrome variant has the same timing,
/// stale-reply guard, and lifecycle behavior.
class PlayerStatisticsOverlay extends StatefulWidget {
  /// Prefer letterboxing over covering the picture, within the host's safe
  /// area. A smaller gap cannot hold the header and a usable scroll region.
  static Rect placement({required Rect viewport, required Rect video}) {
    final visibleVideo = video.intersect(viewport);
    if (visibleVideo.isEmpty) return viewport;
    final above = Rect.fromLTRB(
      viewport.left,
      viewport.top,
      viewport.right,
      visibleVideo.top,
    );
    if (above.height >= 150) return above;
    final left = Rect.fromLTRB(
      viewport.left,
      viewport.top,
      visibleVideo.left,
      viewport.bottom,
    );
    if (left.width >= 220 && left.height >= 150) return left;
    return visibleVideo;
  }

  const PlayerStatisticsOverlay({
    super.key,
    required this.player,
    required this.position,
    required this.duration,
    required this.playbackRate,
    required this.currentIndex,
    required this.episodeLabel,
    required this.onClose,
    this.active = true,
    this.loadSample,
    this.displaySize,
  });

  final NativePlayer? player;
  final ValueListenable<Duration> position;
  final Duration duration;
  final double playbackRate;
  final int currentIndex;
  final String episodeLabel;
  final bool active;
  final PlayerLoadSample? Function()? loadSample;
  final Size? displaySize;
  final VoidCallback onClose;

  @override
  State<PlayerStatisticsOverlay> createState() =>
      _PlayerStatisticsOverlayState();
}

class _PlayerStatisticsOverlayState extends State<PlayerStatisticsOverlay>
    with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 1);
  static const _unsupported = '—';
  static const _blockedValueMarkers = <String>[
    '://',
    'www.',
    'token=',
    'key=',
    'secret=',
    'signature=',
    'preurl=',
    'exception',
  ];
  static final _technicalValue = RegExp(r'^[A-Za-z0-9 ._+/\-:;,()\[\]]+$');
  static final _urlLike = RegExp(
    r'(?:https?[:/]|www\.|\.(?:com|net|org|cn|io)(?:/|$))',
    caseSensitive: false,
  );
  static final _lineBreak = RegExp(r'[\r\n\t]+');

  final Stopwatch _pollClock = Stopwatch()..start();
  Timer? _pollTimer;
  Duration? _lastPollStarted;
  bool _requestInFlight = false;
  bool _appActive = true;
  int _generation = 0;
  NativePlaybackStatistics _statistics = const NativePlaybackStatistics();
  PlayerLoadSample? _sample;
  List<_StatLine> _visibleRows = const [];
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appActive = playbackAppIsActive(WidgetsBinding.instance.lifecycleState);
    _startPolling();
  }

  @override
  void didUpdateWidget(covariant PlayerStatisticsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final playerChanged = !identical(oldWidget.player, widget.player);
    final episodeChanged =
        oldWidget.currentIndex != widget.currentIndex ||
        oldWidget.episodeLabel != widget.episodeLabel;
    final activeChanged = oldWidget.active != widget.active;
    if (!playerChanged && !episodeChanged && !activeChanged) return;

    if (playerChanged || episodeChanged) {
      // The next frame must never show a metric from the previous player or
      // episode. Invalidate any reply that was already in flight as well.
      ++_generation;
      _statistics = const NativePlaybackStatistics();
      _sample = null;
      _decoderName = null;
      _visibleRows = const [];
      _copied = false;
    }
    _syncPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = playbackAppIsActive(state);
    if (active == _appActive) return;
    _appActive = active;
    _syncPolling();
  }

  bool get _pollingActive => _appActive && widget.active;

  void _syncPolling() {
    if (_pollingActive) {
      _startPolling();
    } else {
      _stopPolling();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!mounted || !_pollingActive) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    ++_generation;
  }

  Future<void> _poll() async {
    if (!mounted || !_pollingActive || _requestInFlight) return;
    final now = _pollClock.elapsed;
    final previous = _lastPollStarted;
    if (previous != null && now - previous < _pollInterval) return;

    _requestInFlight = true;
    _lastPollStarted = now;
    final generation = ++_generation;
    final player = widget.player;
    NativePlaybackStatistics statistics;
    try {
      statistics =
          await player?.readStatistics() ?? const NativePlaybackStatistics();
    } catch (_) {
      statistics = const NativePlaybackStatistics();
    }
    final decoderName = identical(widget.player, player)
        ? player?.decoderName
        : null;
    _requestInFlight = false;
    if (!mounted ||
        !_pollingActive ||
        generation != _generation ||
        !identical(widget.player, player)) {
      return;
    }

    PlayerLoadSample? sample;
    try {
      sample = widget.loadSample?.call();
    } catch (_) {
      sample = null;
    }
    setState(() {
      _statistics = statistics;
      _sample = sample;
      _decoderName = decoderName;
      _copied = false;
    });
  }

  String? _decoderName;

  @override
  void dispose() {
    _stopPolling();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String get _playerState {
    final player = widget.player;
    if (player == null || !player.isCreated) return _unsupported;
    if (player.completed) return '已结束';
    if (player.buffering) return '缓冲中';
    if (player.playing || player.playWhenReady) return '播放中';
    return '已暂停';
  }

  String _safeEpisodeLabel(String raw) {
    final safe = raw.trim().replaceAll(_lineBreak, ' ');
    if (safe.isEmpty || safe.length > 60) return _unsupported;
    final lower = safe.toLowerCase();
    if (_blockedValueMarkers.any(lower.contains) || _urlLike.hasMatch(safe)) {
      return _unsupported;
    }
    return safe;
  }

  String _safeTechnicalLabel(String? raw) {
    final safe = raw?.trim();
    if (safe == null || safe.isEmpty || safe.length > 160) {
      return _unsupported;
    }
    final lower = safe.toLowerCase();
    if (_blockedValueMarkers.any(lower.contains) ||
        _urlLike.hasMatch(safe) ||
        !_technicalValue.hasMatch(safe)) {
      return _unsupported;
    }
    return safe;
  }

  String _bitrate(int? bitsPerSecond) {
    if (bitsPerSecond == null) return _unsupported;
    if (bitsPerSecond >= 1000000) {
      return '${_trimNumber(bitsPerSecond / 1000000)} Mbps';
    }
    if (bitsPerSecond >= 1000) {
      return '${_trimNumber(bitsPerSecond / 1000)} kbps';
    }
    return '$bitsPerSecond bps';
  }

  String _bufferedDuration(int? milliseconds) {
    if (milliseconds == null) return _unsupported;
    if (milliseconds < 1000) return '$milliseconds ms';
    return '${_trimNumber(milliseconds / 1000)} s';
  }

  String _trimNumber(num value) {
    final fixed = value.toDouble().toStringAsFixed(2);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _duration(Duration? value) {
    if (value == null) return _unsupported;
    final milliseconds = math.max(0, value.inMilliseconds);
    final totalSeconds = milliseconds ~/ 1000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds ~/ 60) % 60;
    final seconds = totalSeconds % 60;
    final fraction = milliseconds % 1000;
    final base =
        '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
    return fraction == 0
        ? base
        : '$base.${fraction.toString().padLeft(3, '0')}';
  }

  String _loadSource(String? source) => switch (source) {
    'network' => '网络',
    'cacheHit' => '本地缓存',
    'pending' => '等待缓存',
    'prefetchHit' => '预热命中',
    'prefetchPending' => '预热中',
    'offline' => '离线',
    'warm' => '预热',
    _ => _unsupported,
  };

  String _loadOutcome(String? outcome) => switch (outcome) {
    'firstFrame' => '首帧已显示',
    'error' => '加载失败',
    'disposed' => '已取消',
    'superseded' => '已替换',
    _ => _unsupported,
  };

  List<_StatLine> _buildRows(Duration position) {
    final stats = _statistics;
    final sample = _sample;
    final dimensions = stats.videoWidth != null && stats.videoHeight != null
        ? '${stats.videoWidth}x${stats.videoHeight}'
        : _unsupported;
    final display = widget.displaySize;
    final displaySize =
        display != null && display.width > 0 && display.height > 0
        ? '${_trimNumber(display.width)}x${_trimNumber(display.height)}'
        : _unsupported;

    return [
      _StatLine('当前集', _safeEpisodeLabel(widget.episodeLabel), id: 'episode'),
      _StatLine('播放状态', _playerState, id: 'state'),
      _StatLine('画面显示区域', displaySize, id: 'display'),
      _StatLine('视频分辨率', dimensions, id: 'resolution'),
      _StatLine(
        '帧率',
        stats.frameRate == null
            ? _unsupported
            : '${_trimNumber(stats.frameRate!)} fps',
        id: 'frame_rate',
      ),
      _StatLine(
        '视频编码',
        _safeTechnicalLabel(stats.videoCodec),
        id: 'video_codec',
      ),
      _StatLine(
        '视频 MIME',
        _safeTechnicalLabel(stats.videoMimeType),
        id: 'video_mime',
      ),
      _StatLine(
        '音频编码',
        _safeTechnicalLabel(stats.audioCodec),
        id: 'audio_codec',
      ),
      _StatLine(
        '音频 MIME',
        _safeTechnicalLabel(stats.audioMimeType),
        id: 'audio_mime',
      ),
      _StatLine('解码器', _safeTechnicalLabel(_decoderName), id: 'decoder'),
      _StatLine('视频码率', _bitrate(stats.videoBitrate), id: 'video_bitrate'),
      _StatLine('音频码率', _bitrate(stats.audioBitrate), id: 'audio_bitrate'),
      _StatLine('播放位置', _duration(position), id: 'position'),
      _StatLine(
        '总时长',
        widget.duration.inMilliseconds > 0
            ? _duration(widget.duration)
            : _unsupported,
        id: 'duration',
      ),
      _StatLine('播放速度', '${_trimNumber(widget.playbackRate)}x', id: 'rate'),
      _StatLine(
        '缓冲时长',
        _bufferedDuration(stats.bufferedDurationMs),
        id: 'buffer',
      ),
      _StatLine('估计带宽', _bitrate(stats.estimatedBandwidthBps), id: 'bandwidth'),
      _StatLine(
        '渲染帧数',
        stats.renderedFrames?.toString() ?? _unsupported,
        id: 'rendered',
      ),
      _StatLine(
        '丢帧数',
        stats.droppedFrames?.toString() ?? _unsupported,
        id: 'dropped',
      ),
      _StatLine('加载来源', _loadSource(sample?.source), id: 'source'),
      _StatLine('加载结果', _loadOutcome(sample?.outcome), id: 'outcome'),
      _StatLine(
        '本次首帧耗时',
        sample?.firstFrameMs == null
            ? _unsupported
            : '${sample!.firstFrameMs} ms',
        id: 'first_frame',
      ),
      _StatLine(
        '本次取流耗时',
        sample?.stagesMs['address'] == null
            ? _unsupported
            : '${sample!.stagesMs['address']} ms',
        id: 'load_total',
      ),
    ];
  }

  Future<void> _copyVisibleRows() async {
    final rows = _visibleRows;
    final text = [
      '详细统计信息',
      for (final row in rows) '${row.label}: ${row.value}',
    ].join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      // A clipboard failure must not interrupt playback or expose an exception.
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = math.max(0.0, constraints.maxWidth - 24);
        final availableHeight = math.max(0.0, constraints.maxHeight - 24);
        final width = math.min(340.0, availableWidth);
        return Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: width,
              height: math.min(availableHeight, 430),
              child: GestureDetector(
                key: const ValueKey('player-statistics-overlay'),
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                onDoubleTap: () {},
                onLongPress: () {},
                onVerticalDragStart: (_) {},
                onVerticalDragUpdate: (_) {},
                onHorizontalDragStart: (_) {},
                onHorizontalDragUpdate: (_) {},
                child: Material(
                  color: const Color(0xE6222222),
                  elevation: 8,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: const TextScaler.linear(1)),
                    child: Column(
                      children: [
                        _header(),
                        const Divider(height: 1, color: Color(0x33FFFFFF)),
                        Flexible(
                          child: ValueListenableBuilder<Duration>(
                            valueListenable: widget.position,
                            builder: (context, position, _) {
                              final rows = _buildRows(position);
                              _visibleRows = rows;
                              return ListView.builder(
                                key: const ValueKey('player-statistics-scroll'),
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  4,
                                  12,
                                  8,
                                ),
                                itemCount: rows.length,
                                itemBuilder: (context, index) {
                                  final row = rows[index];
                                  return _row(row);
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header() => SizedBox(
    height: 38,
    child: Row(
      children: [
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            '详细统计信息',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('player-statistics-copy'),
          tooltip: _copied ? '已复制' : '复制',
          onPressed: _copyVisibleRows,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: Colors.white70,
          icon: Icon(_copied ? Icons.check : Icons.copy_rounded),
        ),
        IconButton(
          key: const ValueKey('player-statistics-close'),
          tooltip: '关闭',
          onPressed: widget.onClose,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          color: Colors.white70,
          icon: const Icon(Icons.close),
        ),
        const SizedBox(width: 2),
      ],
    ),
  );

  Widget _row(_StatLine line) => Padding(
    key: ValueKey('player-statistics-${line.id}'),
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            line.label,
            style: const TextStyle(
              color: Color(0xB3FFFFFF),
              fontSize: 11,
              height: 1.25,
            ),
          ),
        ),
        Expanded(
          child: Text(
            line.value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              height: 1.25,
              fontFamily: 'monospace',
              fontFamilyFallback: ['Menlo', 'Consolas'],
            ),
          ),
        ),
      ],
    ),
  );
}

class _StatLine {
  const _StatLine(this.label, this.value, {required this.id});

  final String label;
  final String value;
  final String id;
}
