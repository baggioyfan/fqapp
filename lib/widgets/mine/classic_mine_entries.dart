// Legacy presentation from issue #288, fqapp-backup@f329399.
// Reads the current application stores; no legacy data or networking is copied.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../pages/about_page.dart';
import '../../pages/cached_books_page.dart';
import '../../pages/cached_dramas_page.dart';
import '../../pages/library_backup_page.dart';
import '../home/home_design.dart';
import '../home/home_shelf.dart';
import '../home/home_sheet.dart';

/// 手机「我的」的两个主要工具入口。
///
/// 复用桌面入口相同的路由与缓存分流（小说 / 短剧两套存储仍先弹层选择）。
class ClassicMinePrimaryTools extends StatelessWidget {
  const ClassicMinePrimaryTools({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        homeGutter,
        homeSectionGap,
        homeGutter,
        0,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.line, width: 0.8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: _PrimaryTool(
                icon: LucideIcons.hard_drive_download,
                label: '离线缓存',
                onTap: () => _showCacheChoices(context),
              ),
            ),
            Container(width: 0.8, height: 24, color: palette.line),
            Expanded(
              child: _PrimaryTool(
                icon: LucideIcons.archive_restore,
                label: '备份与导入',
                onTap: () => _push(context, const LibraryBackupPage()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 半格工具：最小 56dp 触控高度，文案在格内折行以免横向溢出。
class _PrimaryTool extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PrimaryTool({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: palette.ink),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.3,
                    color: palette.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 我的 页底部的入口列表。应用设置在标题栏齿轮。
///
/// [showTools] 为 false 时只留「关于」，供手机把两个工具提到摘要下方。
class ClassicMineEntries extends StatelessWidget {
  final bool showTools;

  const ClassicMineEntries({super.key, this.showTools = true});

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: homeSectionGap),
      child: Column(
        children: [
          Divider(height: 1, thickness: 0.6, color: palette.line),
          if (showTools) ...[
            ClassicMineEntryRow(
              icon: LucideIcons.hard_drive_download,
              label: '离线缓存',
              onTap: () => _showCacheChoices(context),
            ),
            ClassicMineEntryRow(
              icon: LucideIcons.archive_restore,
              label: '备份与导入',
              onTap: () => _push(context, const LibraryBackupPage()),
            ),
          ],
          ClassicMineEntryRow(
            icon: LucideIcons.info,
            label: '关于',
            onTap: () => _push(context, const AboutPage()),
          ),
        ],
      ),
    );
  }
}

void _push(BuildContext context, Widget page) =>
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

/// 小说离线缓存和短剧离线缓存是两套存储，各自有管理页；这里只做分流。
Future<void> _showCacheChoices(BuildContext context) async {
  await showHomeSheet<void>(
    context: context,
    title: '离线缓存',
    contentPadding: EdgeInsets.zero,
    children: [
      ClassicMineEntryRow(
        icon: LucideIcons.book_open,
        label: '小说离线缓存',
        onTap: () {
          Navigator.pop(context);
          _push(context, const CachedBooksPage());
        },
      ),
      ClassicMineEntryRow(
        icon: LucideIcons.clapperboard,
        label: '短剧离线缓存',
        onTap: () {
          Navigator.pop(context);
          _push(context, const CachedDramasPage());
        },
      ),
      const SizedBox(height: 8),
    ],
  );
}

class ClassicMineEntryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const ClassicMineEntryRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return HomePressable(
      onTap: onTap,
      borderRadius: BorderRadius.zero,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: homeGutter),
          child: Row(
            children: [
              Icon(icon, size: 19, color: palette.ink),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.3,
                    color: palette.ink,
                  ),
                ),
              ),
              Icon(LucideIcons.chevron_right, size: 16, color: palette.muted),
            ],
          ),
        ),
      ),
    );
  }
}
