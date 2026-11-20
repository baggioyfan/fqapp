import 'dart:async';

import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:material_ui/material_ui.dart';

import '../pages/search_page.dart';
import '../services/desktop_platform.dart';
import 'desktop_app_frame.dart' show desktopTab;
import 'desktop_shell_scope.dart';
import 'home/home_design.dart';

/// Custom Fluent / Windows 11 integrated title bar replacing the native OS caption
/// bar when `TitleBarStyle.hidden` is active.
class DesktopWindowBar extends StatefulWidget {
  const DesktopWindowBar({
    super.key,
    required this.canToggleSidebar,
    required this.sidebarExpanded,
  });

  static const double height = 44.0;

  final bool canToggleSidebar;
  final bool sidebarExpanded;

  @override
  State<DesktopWindowBar> createState() => _DesktopWindowBarState();
}

class _DesktopWindowBarState extends State<DesktopWindowBar> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _submitSearch(BuildContext context, String raw) {
    final query = raw.trim();
    FocusManager.instance.primaryFocus?.unfocus();
    DesktopPlatform.navigatorKey.currentState?.push(
      SearchRoute.open<void>(
        context,
        builder: (_) => SearchPage(initialQuery: query.isEmpty ? null : query),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final accent = palette.eink ? palette.ink : HomePalette.accent;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.25,
      child: Container(
        key: const Key('desktop-window-bar'),
        height: DesktopWindowBar.height,
        color: palette.canvas,
        child: Row(
          children: [
            const SizedBox(width: 8),
            ValueListenableBuilder<bool>(
              valueListenable: DesktopShellState.canPop,
              builder: (context, canPop, _) => _TitleBarIconButton(
                key: const Key('desktop-back'),
                tooltip: '返回',
                icon: LucideIcons.arrow_left,
                color: canPop
                    ? palette.ink
                    : palette.muted.withValues(alpha: 0.45),
                palette: palette,
                onTap: () =>
                    DesktopPlatform.navigatorKey.currentState?.maybePop(),
              ),
            ),
            if (widget.canToggleSidebar) ...[
              const SizedBox(width: 2),
              _TitleBarIconButton(
                key: const Key('desktop-sidebar-toggle'),
                tooltip: widget.sidebarExpanded ? '收起导航栏' : '展开导航栏',
                icon: LucideIcons.panel_left,
                color: palette.ink,
                palette: palette,
                onTap: DesktopShellState.toggleSidebar,
              ),
            ],
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: Image.asset(
                'assets/images/app_logo.webp',
                width: 20,
                height: 20,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '什锦铺',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
                color: palette.ink,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) =>
                    unawaited(DesktopPlatform.instance.startWindowDragging()),
                onDoubleTap: () =>
                    unawaited(DesktopPlatform.instance.toggleMaximizeWindow()),
                child: SizedBox(
                  height: DesktopWindowBar.height,
                  child: ValueListenableBuilder<int>(
                    valueListenable: desktopTab,
                    builder: (context, tab, _) => ValueListenableBuilder<bool>(
                      valueListenable: DesktopShellState.onSearchPage,
                      builder: (context, inSearch, _) {
                        if (tab == 1 || inSearch) {
                          return const SizedBox.expand();
                        }
                        return Align(
                          alignment: Alignment.center,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 400),
                            child: SizedBox(
                              height: 30,
                              child: TextField(
                                key: const Key('desktop-search'),
                                controller: _searchCtrl,
                                onSubmitted: (v) => _submitSearch(context, v),
                                textInputAction: TextInputAction.search,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: palette.ink,
                                ),
                                decoration: InputDecoration(
                                  hintText: '搜索书名、作者或作品 ID',
                                  hintStyle: TextStyle(
                                    fontSize: 12.5,
                                    color: palette.muted,
                                  ),
                                  isDense: true,
                                  filled: true,
                                  fillColor: palette.surface,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  prefixIcon: Icon(
                                    LucideIcons.search,
                                    size: 14,
                                    color: palette.muted,
                                  ),
                                  prefixIconConstraints:
                                      const BoxConstraints.tightFor(
                                        width: 32,
                                        height: 30,
                                      ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(color: palette.line),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(
                                      color: accent,
                                      width: 1.2,
                                    ),
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide(color: palette.line),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            _WindowCaptionButtons(palette: palette),
          ],
        ),
      ),
    );
  }
}

class _TitleBarIconButton extends StatefulWidget {
  const _TitleBarIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.palette,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final HomePalette palette;
  final VoidCallback onTap;

  @override
  State<_TitleBarIconButton> createState() => _TitleBarIconButtonState();
}

class _TitleBarIconButtonState extends State<_TitleBarIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: widget.palette.eink
                  ? Duration.zero
                  : const Duration(milliseconds: 100),
              width: 34,
              height: 30,
              decoration: BoxDecoration(
                color: _hovered ? widget.palette.soft : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Icon(widget.icon, size: 16, color: widget.color),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowCaptionButtons extends StatelessWidget {
  const _WindowCaptionButtons({required this.palette});

  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          key: const Key('desktop-window-minimize'),
          tooltip: '最小化',
          palette: palette,
          kind: _CaptionKind.minimize,
          onTap: () => unawaited(DesktopPlatform.instance.minimizeWindow()),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: DesktopPlatform.maximized,
          builder: (context, maximized, _) => _CaptionButton(
            key: const Key('desktop-window-maximize'),
            tooltip: maximized ? '还原' : '最大化',
            palette: palette,
            kind: maximized ? _CaptionKind.restore : _CaptionKind.maximize,
            onTap: () =>
                unawaited(DesktopPlatform.instance.toggleMaximizeWindow()),
          ),
        ),
        _CaptionButton(
          key: const Key('desktop-window-close'),
          tooltip: '关闭',
          palette: palette,
          kind: _CaptionKind.close,
          onTap: () => unawaited(DesktopPlatform.instance.closeWindow()),
        ),
      ],
    );
  }
}

enum _CaptionKind { minimize, maximize, restore, close }

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.tooltip,
    required this.palette,
    required this.kind,
    required this.onTap,
  });

  final String tooltip;
  final HomePalette palette;
  final _CaptionKind kind;
  final VoidCallback onTap;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isClose = widget.kind == _CaptionKind.close;
    final hoverBg = isClose
        ? (widget.palette.eink ? Colors.black : const Color(0xFFC42B1C))
        : widget.palette.soft;
    final fg = (isClose && _hovered) ? Colors.white : widget.palette.ink;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        label: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              width: 46,
              height: DesktopWindowBar.height,
              color: _hovered ? hoverBg : Colors.transparent,
              alignment: Alignment.center,
              child: CustomPaint(
                size: const Size.square(10),
                painter: _CaptionGlyphPainter(kind: widget.kind, color: fg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({required this.kind, required this.color});

  final _CaptionKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    switch (kind) {
      case _CaptionKind.minimize:
        final y = size.height / 2;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      case _CaptionKind.maximize:
        canvas.drawRect(Rect.fromLTWH(0.5, 0.5, 9, 9), paint);
      case _CaptionKind.restore:
        canvas.drawRect(Rect.fromLTWH(0.5, 2.5, 7, 7), paint);
        final back = Path()
          ..moveTo(2.5, 2.5)
          ..lineTo(2.5, 0.5)
          ..lineTo(9.5, 0.5)
          ..lineTo(9.5, 7.5)
          ..lineTo(7.5, 7.5);
        canvas.drawPath(back, paint);
      case _CaptionKind.close:
        canvas.drawLine(const Offset(0.5, 0.5), const Offset(9.5, 9.5), paint);
        canvas.drawLine(const Offset(9.5, 0.5), const Offset(0.5, 9.5), paint);
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) =>
      kind != oldDelegate.kind || color != oldDelegate.color;
}
