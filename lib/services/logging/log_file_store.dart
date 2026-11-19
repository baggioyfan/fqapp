import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'log_codec.dart';
import 'log_models.dart';

/// Append-only UTF-8 writer. Callers serialize append/flush/close operations.
/// Rotation keeps complete entries, even when one entry exceeds [maxBytes].
class FileLogWriter {
  FileLogWriter(this.dir, {this.maxBytes = 1 << 20, this.maxBackups = 1})
    : assert(maxBytes > 0),
      assert(maxBackups >= 0);

  static const String fileName = 'app.log';

  final Directory dir;
  final int maxBytes;
  final int maxBackups;
  File? _current;
  IOSink? _sink;
  int _size = 0;

  String get currentPath => _current?.path ?? '';

  Future<void> open() async {
    if (_sink != null) return;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/$fileName');
    _current = file;
    _size = file.existsSync() ? file.lengthSync() : 0;
    _sink = _openSink(file, FileMode.append);
  }

  IOSink _openSink(File file, FileMode mode) {
    final sink = file.openWrite(mode: mode);
    // IO failures also complete done with an error. Observe that future even
    // when flush reports the same error to the serialized persistence queue.
    unawaited(sink.done.then<void>((_) {}, onError: (Object _) {}));
    return sink;
  }

  Future<void> append(String line) async {
    if (_sink == null) return;
    final encoded = utf8.encode(line);
    final bytes = encoded.length + 1;
    if (_size + bytes > maxBytes) await rotate();
    // Rotation replaces the sink; never retain its previous instance.
    final sink = _sink;
    if (sink == null) return;
    sink.add(encoded);
    sink.add(const [0x0A]);
    _size += bytes;
  }

  Future<void> flush() => _sink?.flush() ?? Future<void>.value();

  Future<void> rotate() async {
    await close();
    final oldest = File(
      '${dir.path}/$fileName${maxBackups == 0 ? '' : '.$maxBackups'}',
    );
    if (oldest.existsSync()) oldest.deleteSync();
    for (var i = maxBackups; i >= 1; i--) {
      final from = File('${dir.path}/$fileName${i == 1 ? '' : '.${i - 1}'}');
      if (from.existsSync()) from.renameSync('${dir.path}/$fileName.$i');
    }
    _size = 0;
    final fresh = File('${dir.path}/$fileName');
    _current = fresh;
    _sink = _openSink(fresh, FileMode.write);
  }

  Future<void> close() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return;
    try {
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}

/// Owns persistence startup, its write queue and flush lifecycle.
///
/// Entries arriving while the directory/history is loading join the startup
/// backlog. Attaching the writer and queuing that backlog is synchronous, so
/// each entry is submitted exactly once before ordinary appends can overtake it.
/// IO failures stay isolated from the logger and its in-memory buffer.
class LogFileStore {
  LogFileStore({
    FileLogWriter Function(Directory)? writerFactory,
    Future<List<LogEntry>> Function(Directory)? historyReader,
  }) : _writerFactory = writerFactory ?? FileLogWriter.new,
       _historyReader = historyReader ?? _readHistory;

  final FileLogWriter Function(Directory) _writerFactory;
  final Future<List<LogEntry>> Function(Directory) _historyReader;
  final List<LogEntry> _startupEntries = [];
  FileLogWriter? _writer;
  Future<void>? _starting;
  Future<void>? _closing;
  Future<void> _pending = Future<void>.value();
  Timer? _flushTimer;
  bool _dirty = false;
  int _generation = 0;

  String? get currentPath => _writer?.currentPath;

  Future<void> start({
    required Future<Directory?> Function() resolveDirectory,
    required List<LogEntry> Function() bufferedEntries,
    required void Function(List<LogEntry>) onHistory,
    Duration flushInterval = const Duration(seconds: 5),
  }) {
    final closing = _closing;
    if (closing != null) {
      return closing.then(
        (_) => start(
          resolveDirectory: resolveDirectory,
          bufferedEntries: bufferedEntries,
          onHistory: onHistory,
          flushInterval: flushInterval,
        ),
      );
    }
    if (_writer != null) return Future<void>.value();
    if (_starting case final starting?) return starting;
    _startupEntries
      ..clear()
      ..addAll(bufferedEntries());
    final completion = Completer<void>();
    final starting = completion.future;
    _starting = starting;
    unawaited(
      _start(
        _generation,
        resolveDirectory,
        onHistory,
        flushInterval,
      ).whenComplete(() {
        if (identical(_starting, starting)) _starting = null;
        completion.complete();
      }),
    );
    return starting;
  }

  Future<void> _start(
    int generation,
    Future<Directory?> Function() resolveDirectory,
    void Function(List<LogEntry>) onHistory,
    Duration flushInterval,
  ) async {
    FileLogWriter? candidate;
    try {
      final directory = await resolveDirectory();
      if (directory == null || generation != _generation) return;
      candidate = _writerFactory(directory);
      await candidate.open();
      if (generation != _generation) return;
      final history = await _historyReader(directory);
      if (generation != _generation) return;

      final writer = candidate;
      _writer = writer;
      candidate = null;
      final backlog = List<LogEntry>.of(_startupEntries);
      _startupEntries.clear();
      for (final entry in backlog) {
        _queueAppend(writer, entry);
      }
      onHistory(history);
      // Startup must observe an IO failure instead of attaching a dead sink.
      // Ordinary flush callers remain best-effort and never see that failure.
      final initialFlush = _pending.then((_) => writer.flush());
      final settled = initialFlush.catchError((Object _) {});
      _pending = settled;
      await initialFlush;
      if (identical(settled, _pending)) _dirty = false;
      if (generation == _generation) {
        stopFlushing();
        _flushTimer = Timer.periodic(flushInterval, (_) {
          if (_dirty) unawaited(flush());
        });
      }
    } catch (_) {
      // A failed initialization must remain retryable and close its IO handle.
      if (generation == _generation) {
        candidate ??= _writer;
        _writer = null;
      }
    } finally {
      if (candidate != null) {
        await _pending;
        try {
          await candidate.close();
        } catch (_) {}
      }
      if (generation == _generation) _startupEntries.clear();
    }
  }

  void append(LogEntry entry) {
    if (_closing != null) return;
    final writer = _writer;
    if (writer == null) {
      if (_starting != null) _startupEntries.add(entry);
      return;
    }
    _queueAppend(writer, entry);
    if (entry.level.index >= LogLevel.warn.index) unawaited(flush());
  }

  void _queueAppend(FileLogWriter writer, LogEntry entry) {
    _dirty = true;
    _pending = _pending
        .then((_) => writer.append(entry.format()))
        .catchError((Object _) {});
  }

  /// Appends and flushes share one queue: IOSink.flush cannot overlap itself.
  Future<void> flush() async {
    final writer = _writer;
    final step = _pending
        .then((_) => writer?.flush())
        .catchError((Object _) {});
    _pending = step;
    await step;
    if (identical(step, _pending)) _dirty = false;
  }

  void stopFlushing() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    final completion = Completer<void>();
    final closing = completion.future;
    _closing = closing;
    unawaited(
      _close().whenComplete(() {
        if (identical(_closing, closing)) _closing = null;
        completion.complete();
      }),
    );
    return closing;
  }

  Future<void> _close() async {
    ++_generation;
    stopFlushing();
    final writer = _writer;
    _writer = null;
    _startupEntries.clear();
    await _starting;
    await _pending;
    try {
      await writer?.close();
    } catch (_) {}
    _pending = Future<void>.value();
    _dirty = false;
  }

  static Future<List<LogEntry>> _readHistory(Directory directory) async {
    try {
      final file = File('${directory.path}/${FileLogWriter.fileName}');
      return LogCodec.parseText(await file.readAsString());
    } catch (_) {
      // An unreadable history file never prevents this session from logging.
      return const [];
    }
  }
}
