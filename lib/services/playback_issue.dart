import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'native_player.dart';

/// User-facing explanations only. Raw exceptions can contain signed video URLs
/// or backend response bodies and must never become the on-screen message.
enum PlaybackIssue {
  network('网络连接异常', '请检查 Wi-Fi 或移动网络，连接正常后重试。'),
  timeout('加载超时', '网络或视频响应较慢，请稍后重试。'),
  unavailable('视频暂时无法播放', '播放地址可能已失效，可以重试获取新地址，或切换其他剧集。'),
  service('播放服务暂时不可用', '请稍后重试，或先观看其他剧集。'),

  /// 片源编码本机解不了（上游只给了 bytevc2/H.266 档）。
  ///
  /// 后端把它包成 500 下发，但这是**内容**问题，不是服务抖动：说成「播放服务
  /// 暂时不可用」会让用户以为等一会儿就好，实际要换一份片源才行。
  unsupported('这一集暂时无法播放', '片源编码本机不支持，可以稍后重试，或先看其他剧集。'),
  decoding('视频解析失败', '视频格式可能不受支持，可以重试或切换其他剧集。'),
  unsupportedCodec(
    '该集暂不支持播放',
    '这一集只提供当前客户端无法解码的视频编码（bytevc2），重试也无法播放，请先观看其他剧集。',
  ),
  unknown('播放失败', '请重试，或切换其他剧集。'),
  empty('暂无可播放剧集', '返回后试试其他作品。');

  final String title;
  final String message;

  const PlaybackIssue(this.title, this.message);

  /// Rust 核心编码门的拒绝文案（`rust/src/endpoints/video.rs` 的
  /// `VideoSourceResolution::CodecRejected` 分支）：上游这一集只给了 bytevc2，
  /// 没有可解码的版本。它和普通 500 同状态码，只能按文案区分；
  /// `test/rust_host_integration_test.dart` 钉住了两侧一致。
  static const unsupportedCodecError = '该视频暂不支持播放';

  /// 结论是确定的：换地址、换档位重试都拿不到能解码的流。
  bool get retryable => this != unsupportedCodec;

  static PlaybackIssue fromError(Object error) {
    if (error is ApiException && error.message == unsupportedCodecError) {
      return unsupportedCodec;
    }
    if (error is TimeoutException) return timeout;
    if (error is NativePlaybackException) {
      final status = error.httpStatusCode;
      // The native crypto reader also reports successful 200/206 responses.
      // Those describe the last transfer, not the cause of a decoder failure.
      if (status != null && status >= 400 && status <= 599) {
        return _fromHttpStatus(status);
      }
      // Media3 PlaybackException codes, retained by the native event bridge.
      return switch (error.errorCode ?? 0) {
        2001 => network, // IO_NETWORK_CONNECTION_FAILED
        2002 => timeout, // IO_NETWORK_CONNECTION_TIMEOUT
        2004 || 2005 => unavailable, // HTTP status / missing file
        2003 || >= 3001 && <= 3004 || >= 4001 && <= 4005 => decoding,
        _ => unknown,
      };
    }
    if (error is ApiException) {
      // 必须先看业务原因，再看状态码：后端把「该视频暂不支持播放」包成 500
      // 下发，按状态码归类会把它说成「播放服务暂时不可用」——那是把内容问题
      // 讲成服务问题，用户会一直等一个不会自己好的错误。
      if (error.message.contains('暂不支持播放')) return unsupported;
      if (error.statusCode case final int status) {
        return _fromHttpStatus(status);
      }
      return error.message == '获取播放地址失败' ? unavailable : service;
    }
    if (error is http.ClientException) {
      // API calls use a local backend. A refused loopback connection says
      // nothing about whether Wi-Fi or mobile data is connected.
      final host = error.uri?.host;
      if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
        return service;
      }
      return network;
    }
    if (error is SocketException) return network;
    return unknown;
  }

  static PlaybackIssue _fromHttpStatus(int status) => switch (status) {
    408 || 504 => timeout,
    429 || >= 500 && <= 599 => service,
    401 || 403 || 404 || 410 || 416 => unavailable,
    _ => unknown,
  };
}
