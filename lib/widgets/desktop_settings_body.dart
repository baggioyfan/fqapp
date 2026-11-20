import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:material_ui/material_ui.dart';

import '../pages/settings_category_page.dart';
import 'home/home_design.dart';
import 'settings/settings_widgets.dart';

class DesktopSettingsBody extends StatefulWidget {
  const DesktopSettingsBody({super.key, required this.categories});
  final List<SettingsCategory> categories;
  @override
  State<DesktopSettingsBody> createState() => _DesktopSettingsBodyState();
}

class _DesktopSettingsBodyState extends State<DesktopSettingsBody> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final category = widget.categories[_selected];
    return LayoutBuilder(
      builder: (context, constraints) {
        final railWidth = constraints.maxWidth >= 960 ? 264.0 : 232.0;
        return Row(
          children: [
            SizedBox(
              width: railWidth,
              child: ColoredBox(
                color: palette.canvas,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
                      child: Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        children: [
                          for (var i = 0; i < widget.categories.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: _categoryRow(i, palette),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: palette.line),
            Expanded(
              child: ColoredBox(
                color: palette.canvas,
                child: KeyedSubtree(
                  key: ValueKey(_selected),
                  child: Navigator(
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder:
                          category.pageBuilder ??
                          (_) => SettingsCategoryPage(
                            title: category.title,
                            items: category.items,
                            itemsBuilder: category.itemsBuilder,
                          ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Keeps the selected check and the category's current value on the same
  /// trailing edge, matching the phone rows instead of hiding the value in
  /// the subtitle on desktop only.
  Widget _categoryRow(int index, HomePalette palette) {
    final category = widget.categories[index];
    final selected = _selected == index;
    final value = category.value;
    final accent = palette.eink ? palette.ink : HomePalette.accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? palette.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: selected ? Border.all(color: palette.line) : null,
      ),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (selected)
            Positioned(
              left: 0,
              child: Container(
                width: 3,
                height: 20,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          SettingsRow(
            icon: category.icon,
            title: category.title,
            subtitle: category.subtitle,
            showChevron: false,
            trailing: value == null && !selected
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (value != null)
                        Text(
                          value,
                          style: TextStyle(fontSize: 13, color: palette.muted),
                        ),
                      if (value != null && selected) const SizedBox(width: 6),
                      if (selected)
                        Icon(
                          LucideIcons.check,
                          size: 16,
                          color: palette.accentText,
                        ),
                    ],
                  ),
            onTap: () => setState(() => _selected = index),
          ),
        ],
      ),
    );
  }
}
