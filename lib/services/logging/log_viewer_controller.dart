import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../app_log.dart';

/// Presentation-independent state for source selection, filtering and follow.
///
/// The page owns scrolling and platform actions. This controller owns stable
/// entry identities, frozen snapshots and lifecycle-aware polling/expiry.
class LogViewerController extends ChangeNotifier {
  LogViewerController({
    AppLog? appLog,
    Future<String?> Function()? rustReader,
    DateTime Function()? clock,
    this.rustRefresh = const Duration(seconds: 2),
  }) : _appLog = appLog ?? AppLog.instance,
       _rustReader = rustReader ?? RustLogSource.read,
       _clock = clock ?? DateTime.now {
    _appLog.revision.addListener(_onAppChanged);
    _entries = _appLog.entries;
    _displayEntries = _entries;
  }

  final AppLog _appLog;
  final Future<String?> Function() _rustReader;
  final DateTime Function() _clock;
  final Duration rustRefresh;
  final HashSet<LogEntry> _pendingEntries = HashSet<LogEntry>.identity();
  LogSource _source = LogSource.app;
  LogFilterSelection _filters = const LogFilterSelection();
  String _query = '';
  String _normalizedQuery = '';
  bool _playerOnly = false;
  bool _following = true;
  bool _active = true;
  bool _disposed = false;
  int _generation = 0;
  List<LogEntry> _entries = const [];
  List<LogEntry> _displayEntries = const [];
  List<LogEntry> _rustEntries = const [];
  String? _rustText;
  Future<void>? _rustLoading;
  Timer? _rustTimer;
  Timer? _expiryTimer;

  LogSource get source => _source;
  LogFilterSelection get filters => _filters;
  String get query => _query;
  bool get playerOnly => _playerOnly;
  bool get following => _following;
  int get pendingCount => _pendingEntries.length;
  List<LogEntry> get entries => _entries;
  List<LogEntry> get displayEntries => _displayEntries;

  bool get hasFilters =>
      _normalizedQuery.isNotEmpty ||
      _playerOnly ||
      _filters.level != null ||
      _filters.timeWindow != null;

  bool _matches(LogEntry entry, DateTime now) {
    if (_filters.level != null && entry.level != _filters.level) return false;
    if (_playerOnly && entry.tag != 'player-load') return false;
    final window = _filters.timeWindow;
    if (window != null && !entry.time.isAfter(now.subtract(window))) {
      return false;
    }
    return _normalizedQuery.isEmpty ||
        entry.tag.toLowerCase().contains(_normalizedQuery) ||
        entry.message.toLowerCase().contains(_normalizedQuery);
  }

  void _onAppChanged() {
    if (!_disposed && _active && _source == LogSource.app) {
      _acceptEntries(_appLog.entries);
    }
  }

  void _acceptEntries(List<LogEntry> next) {
    final snapshot = List<LogEntry>.unmodifiable(next);
    if (!_following) {
      final previous = HashSet<LogEntry>.identity()..addAll(_entries);
      final now = _clock();
      _pendingEntries.retainAll(snapshot);
      _pendingEntries.removeWhere((entry) => !_matches(entry, now));
      _pendingEntries.addAll(
        snapshot.where(
          (entry) => !previous.contains(entry) && _matches(entry, now),
        ),
      );
    }
    _entries = snapshot;
    if (_following) _refreshDisplay();
    notifyListeners();
  }

  void _refreshDisplay() {
    final now = _clock();
    _displayEntries = List<LogEntry>.unmodifiable(
      _entries.where((entry) => _matches(entry, now)),
    );
    _pendingEntries.clear();
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    final window = _filters.timeWindow;
    if (!_active || !_following || window == null || _displayEntries.isEmpty) {
      return;
    }
    final oldest = _displayEntries
        .map((entry) => entry.time)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = oldest.add(window).difference(_clock());
    _expiryTimer = Timer(
      delay.isNegative
          ? Duration.zero
          : delay + const Duration(milliseconds: 1),
      () {
        if (_disposed) return;
        _refreshDisplay();
        notifyListeners();
      },
    );
  }

  void setQuery(String value) {
    _query = value;
    _normalizedQuery = value.trim().toLowerCase();
    _refreshDisplay();
    notifyListeners();
  }

  void setFilters(LogFilterSelection filters) {
    _filters = filters;
    _refreshDisplay();
    notifyListeners();
  }

  void setPlayerOnly(bool selected) {
    if (selected) selectSource(LogSource.app);
    _playerOnly = selected;
    _refreshDisplay();
    notifyListeners();
  }

  void selectSource(LogSource source) {
    if (_source == source) return;
    ++_generation;
    _source = source;
    if (source == LogSource.rust) _playerOnly = false;
    _entries = source == LogSource.app ? _appLog.entries : _rustEntries;
    _following = true;
    _refreshDisplay();
    notifyListeners();
    _updateRustPolling();
  }

  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    ++_generation;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (active) {
      _onAppChanged();
      _scheduleExpiry();
    }
    _updateRustPolling();
  }

  void pauseFollowing() {
    if (!_following) return;
    _following = false;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    notifyListeners();
  }

  void followLatest() {
    _following = true;
    _refreshDisplay();
    notifyListeners();
  }

  void clearAppView() {
    if (_source != LogSource.app) return;
    _appLog.clear();
    // Clear is explicit even when the current list is frozen.
    _entries = _appLog.entries;
    _refreshDisplay();
    notifyListeners();
  }

  void _updateRustPolling() {
    _rustTimer?.cancel();
    _rustTimer = null;
    if (_disposed || !_active || _source != LogSource.rust) return;
    unawaited(refreshRust());
    _rustTimer = Timer.periodic(rustRefresh, (_) => unawaited(refreshRust()));
  }

  /// Coalesces reads while fencing results across source/lifecycle changes.
  /// A stale completion immediately refreshes the now-current Rust session.
  Future<void> refreshRust() {
    if (_disposed || !_active || _source != LogSource.rust) {
      return Future<void>.value();
    }
    if (_rustLoading case final loading?) return loading;
    final generation = _generation;
    final completion = Completer<void>();
    final loading = completion.future;
    _rustLoading = loading;
    unawaited(
      _readRust(generation).whenComplete(() {
        if (identical(_rustLoading, loading)) _rustLoading = null;
        completion.complete();
        if (!_disposed &&
            _active &&
            _source == LogSource.rust &&
            generation != _generation) {
          unawaited(refreshRust());
        }
      }),
    );
    return loading;
  }

  Future<void> _readRust(int generation) async {
    String? text;
    try {
      text = await _rustReader();
    } catch (_) {
      // Preserve the existing unavailable-source contract for injected readers.
    }
    if (_disposed || !_active || generation != _generation) return;
    if (text == _rustText) return;
    _rustText = text;
    final parsed = text == null ? <LogEntry>[] : RustLogSource.parseText(text);
    final previous = <(DateTime, LogLevel, String, String), Queue<LogEntry>>{};
    (DateTime, LogLevel, String, String) signature(LogEntry entry) =>
        (entry.time, entry.level, entry.tag, entry.message);
    for (final entry in _rustEntries) {
      previous.putIfAbsent(signature(entry), Queue.new).add(entry);
    }
    _rustEntries = List<LogEntry>.unmodifiable([
      for (final entry in parsed)
        if (previous[signature(entry)] case final queue? when queue.isNotEmpty)
          queue.removeFirst()
        else
          entry,
    ]);
    _acceptEntries(_rustEntries);
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _appLog.revision.removeListener(_onAppChanged);
    _rustTimer?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }
}
