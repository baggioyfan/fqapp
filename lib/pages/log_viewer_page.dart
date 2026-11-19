// 日志查看页（fqapp 专有功能，上游没有对应页面）。
//
// Two presentations, one log pipeline. Classic restores the pre-#291 settings
// AppBar from fqapp-backup@f329399 with a Material overflow action and
// `HomeStateView` empty states; archive keeps the Wenku8 rev ebcd7f1 shell
// (`SettingsArchivePage`, glass action, `ContentNotice`). The body reserves the
// header height in both: the classic feature shell paints its opaque AppBar
// over the body, so status bar + toolbar clearance is exactly what the archive
// masthead needs too.
//
// The fqapp log toolbar, filter sheet, export pipeline and the
// frozen-list/follow behaviour are unchanged.

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/app_log.dart';
import '../services/logging/log_export.dart';
import '../services/logging/log_viewer_controller.dart';
import '../services/book_txt_export.dart';
import '../services/playlet_share.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_sheet.dart';
import '../widgets/logs/log_entry_card.dart';
import '../widgets/logs/log_filter_sheet.dart';
import '../widgets/logs/log_viewer_chrome.dart';
import '../widgets/settings/settings_adaptive.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';

enum _LogAction { copy, exportVisible, exportAll, exportBoth, share, clear }

// Note: 查看历史时冻结列表，导出复用 TXT 通道；见本地
// .agents/notes/implemented/feature/2026-10-12-log-viewer-redesign.md。
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key, this.exportSink = const PlatformTxtSink()});

  final TxtSink exportSink;
  static const Duration rustRefresh = Duration(seconds: 2);

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  late final LogViewerController _logs;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _logs = LogViewerController(rustRefresh: LogViewerPage.rustRefresh);
    _logs.addListener(_onLogsChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _onLogsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _logs.removeListener(_onLogsChanged);
    _logs.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logs.setActive(state == AppLifecycleState.resumed);
  }

  void _selectSource(LogSource source) {
    if (_logs.source == source) return;
    _logs.selectSource(source);
    _jumpToLatest();
  }

  void _pauseFollowing() => _logs.pauseFollowing();

  void _followLatest() {
    _logs.followLatest();
    _jumpToLatest();
  }

  void _jumpToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle &&
        notification.metrics.pixels > 24) {
      _pauseFollowing();
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        notification.metrics.pixels > 24) {
      _pauseFollowing();
    }
    return false;
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copy(List<LogEntry> entries) async {
    if (entries.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: formatLogLines(entries)));
      _message('已复制 ${entries.length} 条日志');
    } on PlatformException {
      _message('复制失败，请重试');
    }
  }

  Future<void> _export(
    List<LogEntry> entries,
    LogSource source, {
    required bool all,
  }) async {
    if (_exporting || entries.isEmpty) return;
    final snapshot = LogExportSnapshot(
      source: source,
      entries: entries,
      time: DateTime.now(),
    );
    setState(() => _exporting = true);
    try {
      final target = await widget.exportSink.saveText(
        fileName: snapshot.fileName,
        text: snapshot.text(all: all),
      );
      _message(
        '已导出 ${snapshot.entries.length} 条'
        '${target.isPublic ? '' : '到应用目录'}：${target.path}',
      );
    } on ExportWriteException catch (error) {
      _message('导出失败：${error.message}');
    } catch (_) {
      _message('导出失败，请重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportBoth(List<LogEntry> appEntries) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final now = DateTime.now();
    try {
      final rustEntries = await RustLogSource.readEntries();
      if (!mounted) return;
      final snapshot = CombinedLogExportSnapshot(
        appEntries: appEntries,
        rustEntries: rustEntries,
        time: now,
      );
      if (snapshot.isEmpty) {
        _message(
          rustEntries == null ? '应用暂无日志，核心日志未获取（文件不存在或读取失败）' : '暂无可导出的应用或核心日志',
        );
        return;
      }
      final target = await widget.exportSink.saveText(
        fileName: snapshot.fileName,
        text: snapshot.text,
      );
      _message(
        '已导出应用 ${snapshot.appEntries.length} 条 + 核心 ${snapshot.coreSummary}'
        '${target.isPublic ? '' : '到应用目录'}：${target.path}',
      );
    } on ExportWriteException catch (error) {
      _message('导出失败：${error.message}');
    } catch (_) {
      _message('导出失败，请重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _share(List<LogEntry> entries, LogSource source) async {
    final text = formatLogLines(entries, maxLines: 500);
    // Large stacks can exceed Android's Intent size even below the entry cap.
    if (text.length > 100000) {
      _message('日志内容较多，请使用 TXT 导出');
      return;
    }
    final outcome = await SharePlusLite.share(
      title: '${source.label}日志',
      text: text,
    );
    _message(outcome == ShareLaunchOutcome.launched ? '已调起分享' : '没有可用的分享应用');
  }

  Future<void> _showActions() async {
    FocusManager.instance.primaryFocus?.unfocus();
    // Freeze both the count and payload when opening the menu, so incoming logs
    // cannot silently change what the user chose to copy/export.
    final visible = List<LogEntry>.of(_logs.displayEntries);
    final all = List<LogEntry>.of(_logs.entries);
    final appAll = List<LogEntry>.of(AppLog.instance.entries);
    final source = _logs.source;
    final action = await showHomeSheet<_LogAction>(
      context: context,
      title: '${source.label}日志',
      children: [
        _sheetHint('导出为 TXT 文件，保留完整内容'),
        _actionRow(
          _LogAction.copy,
          LucideIcons.copy,
          '复制筛选结果',
          '${visible.length} 条 · 当前查看的结果',
          enabled: visible.isNotEmpty,
        ),
        _actionRow(
          _LogAction.exportVisible,
          LucideIcons.download,
          '导出筛选结果',
          '${visible.length} 条 · 保存为 TXT',
          enabled: visible.isNotEmpty && !_exporting,
        ),
        _actionRow(
          _LogAction.exportAll,
          LucideIcons.file_down,
          '导出全部',
          '${all.length} 条 · 当前来源，不受筛选影响',
          enabled: all.isNotEmpty && !_exporting,
        ),
        _actionRow(
          _LogAction.exportBoth,
          LucideIcons.files,
          '导出应用 + 核心',
          '应用 ${appAll.length} 条 + 核心日志 · 导出前读取最新内容',
          // The core may have logs even if its tab has never been opened.
          enabled: !_exporting,
        ),
        _actionRow(
          _LogAction.share,
          LucideIcons.share_2,
          '分享筛选结果',
          visible.length > 500
              ? '仅分享最近 500 条，完整内容请导出 TXT'
              : '${visible.length} 条 · 系统分享',
          enabled: visible.isNotEmpty,
        ),
        Divider(height: 17, color: HomePalette.of(context).line),
        _actionRow(
          _LogAction.clear,
          LucideIcons.trash,
          '清空当前视图',
          source == LogSource.app ? '保留已保存的日志文件' : '核心日志由服务维护，不支持清空',
          enabled: source == LogSource.app && all.isNotEmpty,
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _LogAction.copy:
        await _copy(visible);
      case _LogAction.exportVisible:
        await _export(visible, source, all: false);
      case _LogAction.exportAll:
        await _export(all, source, all: true);
      case _LogAction.exportBoth:
        await _exportBoth(appAll);
      case _LogAction.share:
        await _share(visible, source);
      case _LogAction.clear:
        await _confirmClear();
    }
  }

  Widget _sheetHint(String text) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: palette.muted)),
    );
  }

  Widget _actionRow(
    _LogAction action,
    IconData icon,
    String title,
    String subtitle, {
    required bool enabled,
  }) => SettingsRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    enabled: enabled,
    showChevron: false,
    onTap: enabled ? () => Navigator.pop(context, action) : null,
  );

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空当前视图'),
        content: const Text('清空当前可查看的应用日志，保留已保存的日志文件。重启后可能再次显示历史记录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _logs.clearAppView();
  }

  Future<void> _pickFilters() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final result = await showHomeSheet<LogFilterSelection>(
      context: context,
      title: '筛选日志',
      children: [LogFilterSheet(initial: _logs.filters)],
    );
    if (!mounted || result == null) return;
    _logs.setFilters(result);
    _jumpToLatest();
  }

  void _togglePlayerOnly(bool selected) {
    _logs.setPlayerOnly(selected);
    _jumpToLatest();
  }

  void _clearLevel() {
    _logs.setFilters(LogFilterSelection(timeWindow: _logs.filters.timeWindow));
    _jumpToLatest();
  }

  void _clearTimeWindow() {
    _logs.setFilters(LogFilterSelection(level: _logs.filters.level));
    _jumpToLatest();
  }

  void _changeQuery(String value) {
    _logs.setQuery(value);
    _jumpToLatest();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final displayEntries = _logs.displayEntries;
    final indices = <Key, int>{
      for (var i = 0; i < displayEntries.length; i++)
        ObjectKey(displayEntries[i]): displayEntries.length - 1 - i,
    };
    final classic = AppUiScope.isClassic(context);
    return SettingsArchivePage(
      title: '日志',
      code: 'SYSTEM / LOGS',
      actions: [
        if (classic)
          IconButton(
            tooltip: '日志操作',
            icon: const Icon(LucideIcons.ellipsis),
            onPressed: _exporting ? null : _showActions,
          )
        else
          GlassIconButton(
            icon: CupertinoIcons.ellipsis,
            label: '日志操作',
            onPressed: _exporting ? null : _showActions,
          ),
      ],
      child: Padding(
        // The archive header floats above the body; the log toolbar is the
        // page's first row, so reserve its height (fqapp used an AppBar here).
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              LogToolbar(
                controller: _searchController,
                query: _logs.query,
                source: _logs.source,
                playerOnly: _logs.playerOnly,
                filters: _logs.filters,
                onQueryChanged: _changeQuery,
                onPickFilters: _pickFilters,
                onSelectSource: _selectSource,
                onTogglePlayerOnly: _togglePlayerOnly,
                onClearLevel: _clearLevel,
                onClearTimeWindow: _clearTimeWindow,
              ),
              if (_exporting)
                LinearProgressIndicator(
                  minHeight: 2,
                  color: palette.accentText,
                  backgroundColor: palette.line,
                ),
              Expanded(
                child: displayEntries.isEmpty
                    ? _buildEmpty()
                    : NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: ListView.builder(
                          key: const ValueKey('log-list'),
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: displayEntries.length,
                          findChildIndexCallback: (key) => indices[key],
                          itemBuilder: (context, index) {
                            final entry =
                                displayEntries[displayEntries.length -
                                    1 -
                                    index];
                            return LogEntryCard(
                              key: ObjectKey(entry),
                              entry: entry,
                              onCopy: () => _copy([entry]),
                            );
                          },
                        ),
                      ),
              ),
              LogFollowBar(
                count: displayEntries.length,
                following: _logs.following,
                pendingCount: _logs.pendingCount,
                onToggle: _logs.following ? _pauseFollowing : _followLatest,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final filtered = _logs.hasFilters;
    return SettingsNotice(
      icon: filtered ? CupertinoIcons.search : CupertinoIcons.doc_plaintext,
      classicIcon: filtered ? LucideIcons.search : LucideIcons.file_text,
      title: filtered
          ? '没有匹配的日志'
          : _logs.source == LogSource.app
          ? '暂无日志'
          : '暂无核心日志',
      message: filtered ? '试试其他关键词，或调整筛选条件' : '运行应用后，日志会显示在这里',
    );
  }
}
