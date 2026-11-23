import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Visual presentation is independent from light/dark mode, reader paper and
/// the user's shelf layout. Unknown values preserve the existing archive UI.
enum AppThemeStyle {
  classic,
  archive;

  String get label => switch (this) {
    classic => '经典主题',
    archive => '档案主题',
  };

  String get description => switch (this) {
    classic => '老版界面 · 封面书架 · 阅读统计',
    archive => '纸张底色 · 档案编号 · 留白排版',
  };

  /// 只认经典界面：档案版式（纸张底色 / 档案编号 / 留白排版）已从 fork
  /// 移除，历史存档里的 `archive` 一律当作 classic，不做迁移提示。
  static AppThemeStyle fromStorage(Object? value) => AppThemeStyle.classic;
}

/// Device-local theme selection. Loading cannot overwrite a newer UI choice,
/// and writes are serialized so rapid switching keeps the last choice on disk.
class AppThemeStyleStore extends ValueNotifier<AppThemeStyle> {
  /// [missingStyle] 是「没存过偏好时用哪套版式」。
  ///
  /// fork 的缺省是 classic —— 产品只跑经典界面，且 `app_theme_style_lock_test`
  /// 把这条钉死了。上游的缺省是 archive，因为上游那批 widget 测试以档案版式的
  /// 度量写的；需要那个基线的测试自己显式传 [AppThemeStyle.archive]，
  /// 不要靠改这里的缺省去迁就测试。
  AppThemeStyleStore({
    Future<SharedPreferences> Function()? preferences,
    AppThemeStyle missingStyle = AppThemeStyle.classic,
  }) : _missingStyle = missingStyle,
       _preferences = preferences ?? SharedPreferences.getInstance,
       super(missingStyle);

  static final instance = AppThemeStyleStore();
  static const storageKey = 'app_theme_style';

  final AppThemeStyle _missingStyle;
  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();
  bool _loaded = false;
  int _revision = 0;

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final prefs = await _preferences();
      if (revision == _revision && _revision == 0) {
        final stored = prefs.get(storageKey);
        value = stored == null
            ? _missingStyle
            : AppThemeStyle.fromStorage(stored);
      }
      _loaded = true;
    } catch (_) {
      // An optional appearance preference must not block the app. Retry on the
      // next load; keep a choice already made in this session.
    } finally {
      _loading = null;
    }
  }

  /// Applies immediately. A false result means this session changed, but the
  /// choice could not be saved; the caller can show a retryable storage notice.
  Future<bool> select(AppThemeStyle style) {
    ++_revision;
    value = style;
    final saved = _writes.then((_) async {
      try {
        final prefs = await _preferences();
        return await prefs.setString(storageKey, style.name);
      } catch (_) {
        return false;
      }
    });
    _writes = saved.then<void>((_) {});
    return saved;
  }
}
