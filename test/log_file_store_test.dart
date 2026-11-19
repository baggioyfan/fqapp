import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/logging/log_file_store.dart';
import 'package:fqapp/services/logging/log_models.dart';

LogEntry _entry(String message) => LogEntry(
  time: DateTime.utc(2026, 1, 1),
  level: LogLevel.info,
  tag: 'test',
  message: message,
);

void main() {
  test(
    'startup queues concurrent entries exactly once in arrival order',
    () async {
      final directory = Directory('unused-log-test');
      final opening = Completer<void>();
      final opened = Completer<void>();
      final writer = _MemoryWriter(directory, opening: opening, opened: opened);
      var creates = 0;
      var historyReads = 0;
      final old = _entry('history');
      List<LogEntry>? history;
      final store = LogFileStore(
        writerFactory: (_) {
          creates++;
          return writer;
        },
        historyReader: (_) async {
          historyReads++;
          return [old];
        },
      );
      addTearDown(store.close);
      final before = _entry('before');
      final first = store.start(
        resolveDirectory: () async => directory,
        bufferedEntries: () => [before],
        onHistory: (entries) => history = entries,
      );
      await opened.future;
      store.append(_entry('while-opening'));
      final second = store.start(
        resolveDirectory: () async => directory,
        bufferedEntries: () => throw StateError('must not reopen'),
        onHistory: (_) => throw StateError('must not reload'),
      );
      expect(identical(first, second), isTrue);
      opening.complete();
      await first;
      store.append(_entry('after'));
      await store.flush();
      expect(creates, 1);
      expect(historyReads, 1);
      expect(history, [old]);
      expect(writer.lines, [
        before.format(),
        _entry('while-opening').format(),
        _entry('after').format(),
      ]);
      expect(writer.lines.join('\n'), isNot(contains('history')));
    },
  );

  test('concurrent append and flush never overlap writer operations', () async {
    final directory = Directory('unused-log-test');
    final writer = _MemoryWriter(directory, yieldWrites: true);
    final store = LogFileStore(
      writerFactory: (_) => writer,
      historyReader: (_) async => const [],
    );
    addTearDown(store.close);
    await store.start(
      resolveDirectory: () async => directory,
      bufferedEntries: () => const [],
      onHistory: (_) {},
    );
    final flushes = <Future<void>>[];
    for (var i = 0; i < 12; i++) {
      store.append(_entry('entry-$i'));
      flushes.add(store.flush());
    }
    await Future.wait(flushes);
    expect(writer.maxConcurrent, 1);
    expect(writer.lines, [
      for (var i = 0; i < 12; i++) _entry('entry-$i').format(),
    ]);
  });

  test(
    'failed startup closes its writer and can retry with a fresh one',
    () async {
      final directory = Directory('unused-log-test');
      final first = _MemoryWriter(directory)..failOpen = true;
      final second = _MemoryWriter(directory);
      var attempts = 0;
      final store = LogFileStore(
        writerFactory: (_) => attempts++ == 0 ? first : second,
        historyReader: (_) async => const [],
      );
      addTearDown(store.close);
      Future<void> start() => store.start(
        resolveDirectory: () async => directory,
        bufferedEntries: () => [_entry('retained')],
        onHistory: (_) {},
      );
      await start();
      expect(store.currentPath, isNull);
      expect(first.closed, isTrue);
      await start();
      expect(store.currentPath, isNotNull);
      expect(second.lines.single, _entry('retained').format());
    },
  );

  test(
    'initial flush failure detaches its sink and remains retryable',
    () async {
      final directory = Directory('unused-log-test');
      final first = _MemoryWriter(directory)..failFlush = true;
      final second = _MemoryWriter(directory);
      var attempts = 0;
      final store = LogFileStore(
        writerFactory: (_) => attempts++ == 0 ? first : second,
        historyReader: (_) async => const [],
      );
      addTearDown(store.close);
      Future<void> start() => store.start(
        resolveDirectory: () async => directory,
        bufferedEntries: () => [_entry('retained')],
        onHistory: (_) {},
      );
      await start();
      expect(store.currentPath, isNull);
      expect(first.closed, isTrue);
      await start();
      expect(store.currentPath, isNotNull);
      expect(second.lines.single, _entry('retained').format());
    },
  );

  test(
    'closing during startup fences history and closes the pending writer',
    () async {
      final directory = Directory('unused-log-test');
      final opening = Completer<void>();
      final opened = Completer<void>();
      final writer = _MemoryWriter(directory, opening: opening, opened: opened);
      final store = LogFileStore(writerFactory: (_) => writer);
      var historyPublished = false;
      final starting = store.start(
        resolveDirectory: () async => directory,
        bufferedEntries: () => [_entry('before-close')],
        onHistory: (_) => historyPublished = true,
      );
      await opened.future;
      final closing = store.close();
      opening.complete();
      await Future.wait([starting, closing]);
      expect(historyPublished, isFalse);
      expect(writer.closed, isTrue);
      expect(store.currentPath, isNull);
      expect(writer.lines, isEmpty);
    },
  );

  test(
    'rotation shifts every backup without overwriting the latest one',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fqapp-log-backups-',
      );
      final writer = FileLogWriter(directory, maxBytes: 8, maxBackups: 2);
      addTearDown(() async {
        await writer.close();
        await directory.delete(recursive: true);
      });
      await writer.open();
      for (final line in ['first', 'second', 'third']) {
        await writer.append(line);
      }
      await writer.close();
      expect(await File('${directory.path}/app.log').readAsString(), 'third\n');
      expect(
        await File('${directory.path}/app.log.1').readAsString(),
        'second\n',
      );
      expect(
        await File('${directory.path}/app.log.2').readAsString(),
        'first\n',
      );
    },
  );
}

class _MemoryWriter extends FileLogWriter {
  _MemoryWriter(
    super.dir, {
    this.opening,
    this.opened,
    this.yieldWrites = false,
  });

  final Completer<void>? opening;
  final Completer<void>? opened;
  final bool yieldWrites;
  final List<String> lines = [];
  bool failOpen = false;
  bool failFlush = false;
  bool closed = false;
  int _active = 0;
  int maxConcurrent = 0;

  @override
  String get currentPath => '${dir.path}/app.log';

  @override
  Future<void> open() async {
    opened?.complete();
    await opening?.future;
    if (failOpen) throw const FileSystemException('synthetic open failure');
  }

  Future<void> _run(void Function() action) async {
    _active++;
    if (_active > maxConcurrent) maxConcurrent = _active;
    try {
      if (yieldWrites) await Future<void>.delayed(Duration.zero);
      action();
    } finally {
      _active--;
    }
  }

  @override
  Future<void> append(String line) => _run(() => lines.add(line));

  @override
  Future<void> flush() => _run(() {
    if (failFlush) throw const FileSystemException('synthetic flush failure');
  });

  @override
  Future<void> close() => _run(() => closed = true);
}
