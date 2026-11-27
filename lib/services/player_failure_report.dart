import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'platform_channel.dart';
import 'playback_issue.dart';
import 'player_load_diagnostics.dart';

/// Frozen before player teardown so retries and episode switches cannot change
/// the failure being reported. Raw exceptions and stream URLs are not accepted.
class PlayerFailureReport {
  final DateTime time;
  final String version;
  final String title;
  final String bookId;
  final String episodeId;
  final int episode;
  final int attempt;
  final PlaybackIssue issue;
  final PlayerLoadSample? sample;
  final bool duringPlayback;
  final int? errorCode;
  final int? httpStatusCode;
  final int? upstreamCode;

  PlayerFailureReport({
    required this.version,
    required String title,
    required String bookId,
    required String episodeId,
    required this.episode,
    required this.attempt,
    required this.issue,
    required this.sample,
    required this.duringPlayback,
    required int? errorCode,
    required int? httpStatusCode,
    required this.upstreamCode,
  }) : time = DateTime.now(),
       title = _safeText(title),
       bookId = _safeText(bookId),
       episodeId = _safeText(episodeId),
       errorCode = errorCode != null && errorCode >= 1 && errorCode <= 9999
           ? errorCode
           : null,
       httpStatusCode =
           httpStatusCode != null &&
               httpStatusCode >= 100 &&
               httpStatusCode <= 599
           ? httpStatusCode
           : null;

  String get stage =>
      duringPlayback ? 'playback' : sample?.failureStage ?? 'other';

  String get stageLabel => switch (stage) {
    'address' => '获取播放地址',
    'releaseWait' => '释放上一播放器',
    'history' => '读取播放进度',
    'pagingBeforeCreate' || 'pagingBeforePlay' => '等待切集',
    'create' => '创建播放器',
    'initialize' => '初始化播放器',
    'autoplayWait' => '等待播放',
    'firstFrame' => '等待首帧',
    'playback' => '播放中',
    _ => '未知阶段',
  };

  String get summary => [
    stageLabel,
    issue.name,
    if (httpStatusCode != null) 'HTTP $httpStatusCode',
    if (errorCode != null) '播放器 $errorCode',
    if (upstreamCode != null) '上游 $upstreamCode',
  ].join(' · ');

  Future<String> text() async {
    Map<String, Object?> environment = const {};
    if (Platform.isAndroid) {
      try {
        environment =
            await const AppMethodChannel('fqapp/native_player')
                .invokeMapMethod<String, Object?>('getDiagnosticEnvironment')
                .timeout(const Duration(seconds: 2)) ??
            const {};
      } on MissingPluginException {
        // Other platform hosts can still copy the frozen playback details.
      } on PlatformException {
        // Environment collection must not prevent copying the failure itself.
      } on TimeoutException {
        // A busy platform channel must not leave the copy action waiting.
      }
    }
    return [
      '什锦铺播放诊断',
      '应用版本：$version',
      if (Platform.isAndroid)
        '设备：${_safeText(environment['model'] as String? ?? '未获取')}',
      '系统：${_safeText(environment['system'] as String? ?? '${Platform.operatingSystem} ${Platform.operatingSystemVersion}')}',
      '失败时间：${time.toIso8601String()}',
      '作品：$title',
      '作品 ID：$bookId',
      '集数：第 $episode 集',
      '剧集 ID：$episodeId',
      '播放尝试：$attempt',
      '错误分类：${issue.name}',
      '失败阶段：$stageLabel ($stage)',
      if (httpStatusCode != null) 'HTTP 状态：$httpStatusCode',
      if (errorCode != null) '播放器错误码：$errorCode',
      if (upstreamCode != null) '上游错误码：$upstreamCode',
      if (sample != null) '加载记录：${jsonEncode(sample!.toJson())}',
    ].join('\n');
  }

  static String _safeText(String value) =>
      AppLog.sanitizeLogText(value).replaceAll(RegExp(r'[\r\n\t]'), ' ');
}
