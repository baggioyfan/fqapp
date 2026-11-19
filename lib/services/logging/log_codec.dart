import 'log_models.dart';

/// Shared text contract for capture, restored history, Rust polling and export.
class LogCodec {
  LogCodec._();

  /// Redacts secrets from one log line before it is buffered or written.
  ///
  /// Capture-layer filter: every path into the application logger — errors,
  /// the debugPrint passthrough, business logs — funnels through [sanitizeText],
  /// so a stray URL or token in an exception or a debug print cannot land
  /// in the buffer, the log file, or an export. Deliberately narrow so
  /// the log viewer stays useful: only the per-launch loopback capability
  /// path, bearer/authorization/cookie credentials, and values of
  /// known-secret keys are replaced; routes, ids, timings and ordinary
  /// text pass through untouched.
  ///
  /// A `Cookie:` header value is redacted to end of line: the whole header
  /// is credential material (`a=b; c=d`), and splitting it would leak the
  /// tail. Standalone long hex/base64 blobs are *not* redacted — without
  /// a sensitive key around them they are indistinguishable from ids.
  static String sanitizeText(String input) {
    var out = input;
    out = out.replaceAllMapped(
      _sessionPathPattern,
      (_) => '/_session/<redacted>',
    );
    out = out.replaceAllMapped(_authorizationPattern, (match) {
      final bearer = match.group(2);
      return bearer == null
          ? '${match.group(1)}<redacted>'
          : '${match.group(1)}Bearer <redacted>';
    });
    out = out.replaceAllMapped(
      _bareBearerPattern,
      (match) => '${match.group(1)}<redacted>',
    );
    out = out.replaceAllMapped(
      _cookiePattern,
      (match) => '${match.group(1)}<redacted>',
    );
    out = out.replaceAllMapped(
      _sensitiveQueryPattern,
      (match) => '${match.group(1)}<redacted>',
    );
    out = out.replaceAllMapped(
      _sensitiveAssignmentPattern,
      (match) => '${match.group(1)}<redacted>',
    );
    return out;
  }

  /// `/_session/<capability>/…` — the per-launch loopback capability.
  static final _sessionPathPattern = RegExp(r'''/_session/[^/\s?#'"<>]+''');

  /// `Authorization: [Bearer ]<credential>` (case-insensitive).
  static final _authorizationPattern = RegExp(
    r'''([Aa]uthorization\s*[:=]\s*["']?)(Bearer\s+)?[^\s"'\n,;]+''',
  );

  /// Bare `Bearer <credential>` without an `Authorization:` prefix.
  static final _bareBearerPattern = RegExp(r'''([Bb]earer\s+)[^\s"'\n,;]+''');

  /// `Cookie: <whole header value>` — redacted to end of line.
  static final _cookiePattern = RegExp(r'([Cc]ookie\s*[:=]\s*)[^\n]*');

  /// Keys whose values are secret material (query `?key=value` and
  /// free-text/JSON `key: value` / `key=value` share this set).
  static const _sensitiveKeys =
      'token|access_token|refresh_token|id_token|auth|authorization|'
      'password|passwd|pwd|secret|client_secret|api_key|apikey|key|'
      'key_hex|secret_key|access_key|capability|session|session_id|'
      'sessionid|cookie|sign|signature|credential|credentials|'
      'private_key|spade_a|device_token';

  static final _sensitiveQueryPattern = RegExp(
    '([?&](?:$_sensitiveKeys)=)[^&\\s"\'#]*',
    caseSensitive: false,
  );

  static final _sensitiveAssignmentPattern = RegExp(
    '((?:^|[\\s{"\'\\(,\\[])(?:$_sensitiveKeys)\\s*["\']?\\s*[:=]\\s*["\']?)'
    // 不吃 `Bearer …`：`Authorization: Bearer <token>` 由上面的
    // Authorization/Bearer 轮次处理，这里再匹配会把 `Bearer` 一词
    // 当成值、留下裸 token（或把已脱敏的占位符再包一层）。
    '(?!Bearer\\s)[^"\'\\s,}\\]]+',
    caseSensitive: false,
  );

  /// 解析落盘行：形态是 `[级别] ISO 标签: 消息`。消息可以多行，匹配不上的行
  /// 按「上一条的续行」处理，多行异常栈回读后仍是同一条。
  static List<LogEntry> parseLines(
    List<String> lines, {
    bool unzonedTimestampsAreUtc = false,
  }) {
    final result = <LogEntry>[];
    LogLevel? level;
    DateTime? time;
    String? tag;
    final message = StringBuffer();

    void flushEntry() {
      final l = level;
      final t = time;
      final g = tag;
      if (l == null || t == null || g == null) return;
      result.add(
        LogEntry(
          time: t,
          level: l,
          tag: sanitizeText(g),
          message: sanitizeText(message.toString()),
        ),
      );
    }

    for (final line in lines) {
      final match = _entryPattern.firstMatch(line);
      if (match == null) {
        // 续行接到上一条；文件开头的无主续行直接忽略。
        if (level != null) {
          if (message.isNotEmpty) message.write('\n');
          message.write(line);
        }
        continue;
      }
      flushEntry();
      level = _levelFromToken(match.group(1)!);
      time = _parseTimestamp(
        match.group(2)!,
        unzonedTimestampsAreUtc: unzonedTimestampsAreUtc,
      );
      tag = match.group(3)!;
      message
        ..clear()
        ..write(match.group(4)!);
    }
    flushEntry();
    return result;
  }

  static final RegExp _entryPattern = RegExp(
    r'^\[([DIWE])\] (\S+) ([^:]*): (.*)$',
  );

  static DateTime _parseTimestamp(
    String stamp, {
    required bool unzonedTimestampsAreUtc,
  }) {
    final parsed = DateTime.tryParse(stamp);
    if (parsed == null) return DateTime.now();
    if (!unzonedTimestampsAreUtc || parsed.isUtc) return parsed;
    // Preserve wall-clock components, not the host's interpretation of them.
    // Legacy Rust core_log writes UTC without Z; application logs stay local.
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }

  static LogLevel _levelFromToken(String token) => switch (token) {
    'E' => LogLevel.error,
    'W' => LogLevel.warn,
    'I' => LogLevel.info,
    _ => LogLevel.debug,
  };

  /// A file's final newline is not a continuation of its last entry.
  static List<LogEntry> parseText(
    String text, {
    bool unzonedTimestampsAreUtc = false,
  }) {
    final lines = text.split(RegExp(r'\r\n|\n|\r'));
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return parseLines(lines, unzonedTimestampsAreUtc: unzonedTimestampsAreUtc);
  }
}

/// Formats the complete snapshot, or its latest [maxLines] entries.
/// Redaction is repeated at this output boundary for caller-created entries.
String formatLogLines(List<LogEntry> entries, {int? maxLines}) {
  if (maxLines != null && maxLines < 0) {
    throw ArgumentError.value(maxLines, 'maxLines', 'must not be negative');
  }
  final omitted = maxLines != null && entries.length > maxLines
      ? entries.length - maxLines
      : 0;
  final lines = entries
      .skip(omitted)
      .map((entry) => LogCodec.sanitizeText(entry.format()));
  final text = lines.join('\n');
  return omitted == 0 ? text : '... 省略 $omitted 条 ...\n$text';
}
