import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:material_ui/material_ui.dart';

import '../pages/settings_page.dart';
import '../services/desktop_platform.dart';
import 'desktop_shell_scope.dart';
import 'desktop_window_bar.dart';
import 'home/home_design.dart';

final desktopTab = ValueNotifier<int>(0);

class DesktopAppFrame extends StatelessWidget {
  const DesktopAppFrame({super.key, required this.child});
  final Widget child;

  static const _destinations = <({IconData icon, String label})>[
    (icon: LucideIcons.house, label: '首页'),
    (icon: LucideIcons.clapperboard, label: '短剧'),
    (icon: LucideIcons.library_big, label: '书架'),
    (icon: LucideIcons.circle_user_round, label: '我的'),
  ];

  void _select(int index) {
    DesktopPlatform.navigatorKey.currentState?.popUntil(
      (route) => route.isFirst,
    );
    desktopTab.value = index;
  }

  void _openSettings() {
    if (DesktopShellState.onSettingsPage.value) return;
    DesktopPlatform.navigatorKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
  }

  @override
  // MaterialApp.builder is above its Navigator. The frame's own tooltips need
  // an overlay here; the page Navigator below cannot host a sibling's tooltip.
  Widget build(BuildContext context) => Overlay.wrap(
    child: ValueListenableBuilder<bool>(
      valueListenable: DesktopPlatform.fullscreen,
      builder: (context, full, _) {
        if (full) return child;
        final palette = HomePalette.of(context);
        return DesktopShellScope(
          hasFrame: true,
          child: ValueListenableBuilder<DesktopReaderChrome?>(
            valueListenable: DesktopShellState.readerChrome,
            builder: (context, readerChrome, _) {
              final hideNavPane = readerChrome != null;
              final frameCanvas = readerChrome?.barBackground ?? palette.canvas;
              final frameLine = readerChrome?.border ?? palette.line;
              return Material(
                color: frameCanvas,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final canExpand = constraints.maxWidth >= 1100;
                    return ValueListenableBuilder<bool>(
                      valueListenable: DesktopShellState.sidebarExpanded,
                      builder: (context, userExpanded, _) {
                        final expanded = canExpand && userExpanded;
                        return Column(
                          children: [
                            DesktopWindowBar(
                              canToggleSidebar: !hideNavPane && canExpand,
                              sidebarExpanded: expanded,
                              readerChrome: readerChrome,
                            ),
                            Expanded(
                              child: Row(
                                children: [
                                  if (!hideNavPane)
                                    _DesktopNavPane(
                                      key: const Key('desktop-nav-pane'),
                                      expanded: expanded,
                                      palette: palette,
                                      onSelectTab: _select,
                                      onOpenSettings: _openSettings,
                                    ),
                                  Expanded(
                                    child: hideNavPane
                                        ? DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: frameCanvas,
                                              border: Border(
                                                top: BorderSide(
                                                  color: frameLine,
                                                ),
                                              ),
                                            ),
                                            child: child,
                                          )
                                        : DecoratedBox(
                                            decoration: BoxDecoration(
                                              color: palette.canvas,
                                              border: Border(
                                                top: BorderSide(
                                                  color: palette.line,
                                                ),
                                                left: BorderSide(
                                                  color: palette.line,
                                                ),
                                              ),
                                              borderRadius:
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(
                                                      10,
                                                    ),
                                                  ),
                                            ),
                                            child: ClipRRect(
                                              borderRadius:
                                                  const BorderRadius.only(
                                                    topLeft: Radius.circular(
                                                      10,
                                                    ),
                                                  ),
                                              child: child,
                                            ),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              );
            },
          ),
        );
      },
    ),
  );
}

class _DesktopNavPane extends StatelessWidget {
  const _DesktopNavPane({
    super.key,
    required this.expanded,
    required this.palette,
    required this.onSelectTab,
    required this.onOpenSettings,
  });

  final bool expanded;
  final HomePalette palette;
  final ValueChanged<int> onSelectTab;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final width = expanded ? 200.0 : 68.0;
    return AnimatedContainer(
      duration: palette.eink
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      width: width,
      color: palette.canvas,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final visualExpanded = expanded && constraints.maxWidth >= 140;
          return ValueListenableBuilder<int>(
            valueListenable: desktopTab,
            builder: (context, selectedIndex, _) =>
                ValueListenableBuilder<bool>(
                  valueListenable: DesktopShellState.onSettingsPage,
                  builder: (context, inSettings, _) => Column(
                    children: [
                      const SizedBox(height: 6),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            children: [
                              for (
                                var i = 0;
                                i < DesktopAppFrame._destinations.length;
                                i++
                              )
                                _FluentNavItem(
                                  key: ValueKey('desktop-nav-tab-$i'),
                                  icon: DesktopAppFrame._destinations[i].icon,
                                  label: DesktopAppFrame._destinations[i].label,
                                  selected: !inSettings && selectedIndex == i,
                                  expanded: visualExpanded,
                                  palette: palette,
                                  onTap: () => onSelectTab(i),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Divider(
                          height: 1,
                          thickness: 1,
                          color: palette.line,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _FluentNavItem(
                        key: const Key('desktop-settings'),
                        icon: LucideIcons.settings,
                        label: '设置',
                        selected: inSettings,
                        expanded: visualExpanded,
                        palette: palette,
                        onTap: onOpenSettings,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
          );
        },
      ),
    );
  }
}

class _FluentNavItem extends StatefulWidget {
  const _FluentNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.expanded,
    required this.palette,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool expanded;
  final HomePalette palette;
  final VoidCallback onTap;

  @override
  State<_FluentNavItem> createState() => _FluentNavItemState();
}

class _FluentNavItemState extends State<_FluentNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final accent = palette.eink ? palette.ink : HomePalette.accent;
    final bg = widget.selected
        ? palette.surface
        : (_hovered ? palette.soft : Colors.transparent);
    final fg = widget.selected ? palette.ink : palette.muted;
    final content = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.25,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Semantics(
            button: true,
            selected: widget.selected,
            label: widget.label,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: palette.eink
                    ? Duration.zero
                    : const Duration(milliseconds: 110),
                height: widget.expanded ? 40 : 48,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                  border: widget.selected
                      ? Border.all(color: palette.line)
                      : null,
                ),
                child: Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    if (widget.selected)
                      Positioned(
                        left: 0,
                        child: Container(
                          width: 3,
                          height: widget.expanded ? 16 : 18,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    if (widget.expanded)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Icon(
                              widget.icon,
                              size: 18,
                              color: widget.selected ? accent : fg,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: widget.selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: palette.ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.icon,
                              size: 18,
                              color: widget.selected ? accent : fg,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: widget.selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: fg,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (widget.expanded) return content;
    return Tooltip(message: widget.label, child: content);
  }
}
