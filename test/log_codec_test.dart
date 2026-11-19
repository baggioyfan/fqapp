import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/logging/log_codec.dart';
import 'package:fqapp/services/logging/log_export.dart';
import 'package:fqapp/services/logging/log_models.dart';
import 'package:fqapp/services/logging/rust_log_source.dart';

void main() {
  test(
    'text parsing removes file terminators but preserves multiline stacks',
    () {
      final entries = LogCodec.parseText(
        'orphan continuation\n'
        '[E] 2026-01-01T00:00:00Z core: failed\n'
        '#0 first\n#1 last\n\n',
      );
      expect(entries, hasLength(1));
      expect(entries.single.level, LogLevel.error);
      expect(entries.single.message, 'failed\n#0 first\n#1 last');
    },
  );

  test('Windows and Unix files produce identical entries and stack lines', () {
    const text = '[W] 2026-01-01T00:00:00Z core: warning\n#0 stack\n';
    final unix = LogCodec.parseText(text);
    final windows = LogCodec.parseText(text.replaceAll('\n', '\r\n'));
    expect(windows.single.format(), unix.single.format());
    expect(windows.single.message, 'warning\n#0 stack');
  });

  test('only Rust source treats timestamps without a zone as UTC', () {
    const line = '[I] 2026-11-18T19:27:26 core: just written\n';
    final core = RustLogSource.parseText(line).single;
    final app = LogCodec.parseText(line).single;
    expect(core.time, DateTime.utc(2026, 11, 18, 19, 27, 26));
    expect(core.time.isUtc, isTrue);
    expect(core.format(), contains('2026-11-18T19:27:26.000Z'));
    expect(app.time.isUtc, isFalse);
  });

  test('Rust parsing preserves explicit UTC and offset timestamps', () {
    final entries = RustLogSource.parseText(
      '[I] 2026-11-18T19:27:26Z core: UTC\n'
      '[I] 2026-11-19T03:27:26+08:00 core: offset\n',
    );
    expect(entries[0].time, DateTime.utc(2026, 11, 18, 19, 27, 26));
    expect(entries[1].time, entries[0].time);
  });

  test('restored logs and caller-created exports share capture redaction', () {
    const message =
        'Authorization: Bearer synthetic-log-value\n'
        'Cookie: synthetic=session; other=fixture\n'
        'GET /api/x?access_token=synthetic-query&page=2\n'
        'http://127.0.0.1:9/_session/synthetic-capability/src/file';
    final parsed = LogCodec.parseText(
      '[I] 2026-01-01T00:00:00Z core: $message\n',
    );
    final exported = formatLogLines([
      LogEntry(
        time: DateTime.utc(2026),
        level: LogLevel.info,
        tag: 'test',
        message: message,
      ),
    ]);
    for (final text in [parsed.single.message, exported]) {
      expect(text, contains('Bearer <redacted>'));
      expect(text, contains('Cookie: <redacted>'));
      expect(text, contains('access_token=<redacted>&page=2'));
      expect(text, contains('/_session/<redacted>/src/file'));
      expect(text, isNot(contains('synthetic-log-value')));
      expect(text, isNot(contains('synthetic-query')));
      expect(text, isNot(contains('synthetic-capability')));
    }
  });

  test(
    'text formatting retains newest entries with the existing omission marker',
    () {
      final entries = [
        for (var i = 0; i < 3; i++)
          LogEntry(
            time: DateTime.utc(2026),
            level: LogLevel.info,
            tag: 'test',
            message: 'entry-$i',
          ),
      ];
      final text = formatLogLines(entries, maxLines: 1);
      expect(text, startsWith('... 省略 2 条 ...\n'));
      expect(text, endsWith('entry-2'));
      expect(text, isNot(contains('entry-0')));
      expect(formatLogLines(entries, maxLines: 0), '... 省略 3 条 ...\n');
      expect(() => formatLogLines(entries, maxLines: -1), throwsArgumentError);
    },
  );

  test(
    'export snapshots are immutable and combined export distinguishes missing core',
    () {
      final entries = [
        LogEntry(
          time: DateTime.utc(2026),
          level: LogLevel.info,
          tag: 'test',
          message: 'kept',
        ),
      ];
      final snapshot = LogExportSnapshot(
        source: LogSource.app,
        entries: entries,
        time: DateTime.utc(2026),
      );
      final combined = CombinedLogExportSnapshot(
        appEntries: entries,
        rustEntries: null,
        time: DateTime.utc(2026),
      );
      entries.clear();
      expect(snapshot.entries, hasLength(1));
      expect(() => snapshot.entries.clear(), throwsUnsupportedError);
      expect(snapshot.text(all: false), contains('范围：当前筛选结果'));
      expect(combined.text, contains('===== 应用日志 ====='));
      expect(combined.text, contains('kept'));
      expect(combined.text, contains('核心日志：未获取（文件不存在或读取失败）'));
      expect(combined.isEmpty, isFalse);
      final emptyCore = CombinedLogExportSnapshot(
        appEntries: const [],
        rustEntries: const [],
        time: DateTime.utc(2026),
      );
      expect(emptyCore.coreSummary, '0 条');
      expect(emptyCore.isEmpty, isTrue);
    },
  );

  test(
    'Rust source uses the shared parser and treats read failures as unavailable',
    () async {
      addTearDown(() => RustLogSource.reader = null);
      RustLogSource.reader = () async =>
          '[W] 2026-01-01T00:00:00Z core: token=synthetic-value\n';
      expect(
        (await RustLogSource.readEntries())!.single.message,
        'token=<redacted>',
      );
      RustLogSource.reader = () async =>
          throw StateError('synthetic read failure');
      expect(await RustLogSource.readEntries(), isNull);
    },
  );
}
