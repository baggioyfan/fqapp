import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:material_ui/material_ui.dart';

import '../services/boss_key_preferences.dart';
import '../services/boss_key_service.dart';
import '../widgets/app_ui/app_ui_scope.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_archive_page.dart';
import '../widgets/settings/settings_archive_rows.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/wenku/wenku_ui.dart';

/// Desktop settings page for configuring the global boss key.
class BossKeySettingsPage extends StatefulWidget {
  const BossKeySettingsPage({super.key});

  @override
  State<BossKeySettingsPage> createState() => _BossKeySettingsPageState();
}

class _BossKeySettingsPageState extends State<BossKeySettingsPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(BossKeyPreferences.instance.load());
  }

  Future<void> _setEnabled(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await BossKeyService.instance.setEnabled(enabled);
      if (!mounted) return;
      if (!result.ok && result.errorMessage != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(result.errorMessage!)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openRecorder() async {
    if (_busy) return;
    final current = BossKeyPreferences.instance.shortcut.value;
    final updated = await showDialog<BossKeyShortcut>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _BossKeyRecorderDialog(initialShortcut: current),
    );
    if (!mounted || updated == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('老板键已更新为 ${updated.formatLabel()}')));
  }

  Future<void> _resetDefault() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await BossKeyService.instance.updateShortcut(
        BossKeyShortcut.defaultShortcut,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.ok
                ? '已恢复默认快捷键 ${BossKeyShortcut.defaultShortcut.formatLabel()}'
                : (result.errorMessage ?? '恢复默认快捷键失败'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final classic = AppUiScope.isClassic(context);
    final prefs = BossKeyPreferences.instance;
    final service = BossKeyService.instance;

    return SettingsArchivePage(
      title: '老板键',
      code: 'SYSTEM / BOSS KEY',
      child: ListenableBuilder(
        listenable: Listenable.merge([
          prefs.enabled,
          prefs.shortcut,
          service.status,
        ]),
        builder: (context, _) {
          final enabled = prefs.enabled.value;
          final shortcut = prefs.shortcut.value;
          final status = service.status.value;
          final isDefault = shortcut == BossKeyShortcut.defaultShortcut;
          final shortcutLabel = shortcut.formatLabel();

          final rows = <Widget>[
            SettingsToggleRow(
              key: const ValueKey('settings-boss-key-toggle'),
              icon: CupertinoIcons.eye_slash,
              title: '启用老板键',
              description: '按下全局快捷键立即隐藏窗口（含任务栏）并暂停短剧、听书和系统朗读，再按一次恢复',
              value: enabled,
              optimistic: false,
              onChanged: _busy ? null : _setEnabled,
            ),
            if (classic)
              SettingsRow(
                key: const ValueKey('settings-boss-key-shortcut'),
                icon: LucideIcons.keyboard,
                iconTile: true,
                title: '自定义快捷键',
                subtitle: '点击后按下想绑定的组合键（支持隐藏或失焦后全局触发）',
                value: shortcutLabel,
                onTap: _busy ? null : _openRecorder,
              )
            else
              SettingsLinkRow(
                key: const ValueKey('settings-boss-key-shortcut'),
                icon: CupertinoIcons.keyboard,
                title: '自定义快捷键',
                subtitle: '点击后按下想绑定的组合键（支持隐藏或失焦后全局触发）',
                trailing: _ShortcutBadge(label: shortcutLabel),
                onTap: _busy ? null : _openRecorder,
              ),
            if (!isDefault)
              if (classic)
                SettingsRow(
                  key: const ValueKey('settings-boss-key-reset'),
                  icon: LucideIcons.rotate_ccw,
                  iconTile: true,
                  title: '恢复默认快捷键',
                  subtitle:
                      '重置为 ${BossKeyShortcut.defaultShortcut.formatLabel()}',
                  showChevron: false,
                  onTap: _busy ? null : _resetDefault,
                )
              else
                SettingsLinkRow(
                  key: const ValueKey('settings-boss-key-reset'),
                  icon: CupertinoIcons.arrow_counterclockwise,
                  title: '恢复默认快捷键',
                  subtitle:
                      '重置为 ${BossKeyShortcut.defaultShortcut.formatLabel()}',
                  onTap: _busy ? null : _resetDefault,
                ),
          ];

          final notice = _buildStatusNotice(
            context,
            classic: classic,
            enabled: enabled,
            shortcutLabel: shortcutLabel,
            status: status,
          );

          if (classic) {
            return ListView(
              key: const PageStorageKey('settings-boss-key-classic'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                SettingsGroupCard(children: rows),
                const SizedBox(height: 12),
                notice,
              ],
            );
          }

          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                key: const PageStorageKey('settings-boss-key'),
                padding: featurePadding(context).add(
                  EdgeInsets.only(
                    left: MediaQuery.paddingOf(context).left,
                    right: MediaQuery.paddingOf(context).right,
                  ),
                ),
                children: [
                  SettingsPanel(children: rows),
                  const SizedBox(height: 14),
                  notice,
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusNotice(
    BuildContext context, {
    required bool classic,
    required bool enabled,
    required String shortcutLabel,
    required BossKeyStatus status,
  }) {
    final palette = HomePalette.of(context);
    final hasError = status.errorMessage != null;
    final String headline;
    final String body;
    final IconData icon;
    final Color iconColor;

    if (!status.globalHotkeySupported) {
      headline = '当前会话不支持全局老板键';
      body = status.errorMessage ?? '当前桌面会话无法监听隐藏后的全局快捷键，已禁用隐藏以防窗口无法恢复。';
      icon = LucideIcons.triangle_alert;
      iconColor = palette.accentText;
    } else if (hasError) {
      headline = '全局快捷键未生效';
      body = status.errorMessage!;
      icon = LucideIcons.triangle_alert;
      iconColor = palette.accentText;
    } else if (enabled && status.registered) {
      headline = '全局监听已生效（$shortcutLabel）';
      body = '应用隐藏或失去焦点时，再次按下 $shortcutLabel 即可恢复窗口并聚焦；已暂停的播放不会自动恢复。';
      icon = LucideIcons.shield_check;
      iconColor = palette.accentText;
    } else {
      headline = '使用说明';
      body =
          '开启后，随时按下 $shortcutLabel 即可立刻隐藏窗口（同时从任务栏隐藏）并暂停当前短剧、听书和系统朗读；再按一次恢复窗口。';
      icon = LucideIcons.info;
      iconColor = palette.muted;
    }

    final content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18, color: iconColor),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                headline,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: palette.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (classic) {
      return SurfacePanel(padding: const EdgeInsets.all(14), child: content);
    }
    return ContentPanel(padding: const EdgeInsets.all(16), child: content);
  }
}

class _ShortcutBadge extends StatelessWidget {
  const _ShortcutBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.line),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: palette.ink,
        ),
      ),
    );
  }
}

class _BossKeyRecorderDialog extends StatefulWidget {
  const _BossKeyRecorderDialog({required this.initialShortcut});

  final BossKeyShortcut initialShortcut;

  @override
  State<_BossKeyRecorderDialog> createState() => _BossKeyRecorderDialogState();
}

class _BossKeyRecorderDialogState extends State<_BossKeyRecorderDialog> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'boss-key-recorder');
  late BossKeyShortcut _candidate = widget.initialShortcut;
  bool _capturedNew = false;
  String? _error;
  bool _saving = false;
  String? _heldModifiersText;

  @override
  void initState() {
    super.initState();
    unawaited(BossKeyService.instance.beginRecording());
  }

  @override
  void dispose() {
    _focusNode.dispose();
    unawaited(BossKeyService.instance.endRecording());
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (_saving) return KeyEventResult.handled;
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;

    if (event is KeyUpEvent) {
      final held = _formatHeldModifiers(pressed);
      if (held != _heldModifiersText) {
        setState(() => _heldModifiersText = held);
      }
      return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final logical = event.logicalKey;
    final hasModifier =
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.control) ||
        pressed.contains(LogicalKeyboardKey.altLeft) ||
        pressed.contains(LogicalKeyboardKey.altRight) ||
        pressed.contains(LogicalKeyboardKey.alt) ||
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight) ||
        pressed.contains(LogicalKeyboardKey.shift) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight) ||
        pressed.contains(LogicalKeyboardKey.meta);

    if (logical == LogicalKeyboardKey.escape && !hasModifier) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    if (BossKeyShortcut.isModifierLogicalKey(logical)) {
      final effective = {...pressed, logical};
      setState(() {
        _heldModifiersText = _formatHeldModifiers(effective);
        _error = null;
      });
      return KeyEventResult.handled;
    }

    final captured = BossKeyShortcut.fromKeyEvent(event, pressedKeys: pressed);
    if (captured == null) {
      setState(() {
        _heldModifiersText = null;
        _error = '暂不支持该按键，请换用字母、数字或功能键';
      });
      return KeyEventResult.handled;
    }

    setState(() {
      _heldModifiersText = null;
      _candidate = captured;
      _capturedNew = true;
      _error = captured.validationError;
    });
    return KeyEventResult.handled;
  }

  String? _formatHeldModifiers(Set<LogicalKeyboardKey> pressed) {
    final parts = <String>[
      if (pressed.contains(LogicalKeyboardKey.controlLeft) ||
          pressed.contains(LogicalKeyboardKey.controlRight) ||
          pressed.contains(LogicalKeyboardKey.control))
        'Ctrl',
      if (pressed.contains(LogicalKeyboardKey.altLeft) ||
          pressed.contains(LogicalKeyboardKey.altRight) ||
          pressed.contains(LogicalKeyboardKey.alt))
        'Alt',
      if (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
          pressed.contains(LogicalKeyboardKey.shiftRight) ||
          pressed.contains(LogicalKeyboardKey.shift))
        'Shift',
      if (pressed.contains(LogicalKeyboardKey.metaLeft) ||
          pressed.contains(LogicalKeyboardKey.metaRight) ||
          pressed.contains(LogicalKeyboardKey.meta))
        Theme.of(context).platform == TargetPlatform.windows ? 'Win' : 'Super',
    ];
    return parts.isEmpty ? null : '${parts.join(' + ')} + ...';
  }

  Future<void> _save() async {
    if (_saving) return;
    final validation = _candidate.validationError;
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await BossKeyService.instance.updateShortcut(_candidate);
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(_candidate);
      return;
    }
    setState(() {
      _saving = false;
      _error = result.errorMessage ?? '快捷键设置失败，请重试';
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final canSave = !_saving && _candidate.isValid;
    final display = _heldModifiersText ?? _candidate.formatLabel();

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: AlertDialog(
        title: const Text('设置老板键'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '直接按下想要的组合键（例如 Alt + Q、Ctrl + Shift + H 或 F9）。按 Esc 取消。',
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
              const SizedBox(height: 16),
              Container(
                key: const ValueKey('boss-key-recorder-display'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: palette.soft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _error != null
                        ? Theme.of(context).colorScheme.error
                        : palette.line,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  display,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: palette.ink,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (_error != null)
                Text(
                  _error!,
                  key: const ValueKey('boss-key-recorder-error'),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).colorScheme.error,
                  ),
                )
              else
                Text(
                  _capturedNew ? '点击「保存」立即生效' : '录制期间已暂挂当前老板键，不会误隐藏窗口',
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving
                ? null
                : () {
                    setState(() {
                      _candidate = BossKeyShortcut.defaultShortcut;
                      _capturedNew = true;
                      _heldModifiersText = null;
                      _error = null;
                    });
                    _focusNode.requestFocus();
                  },
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('boss-key-recorder-save'),
            onPressed: canSave ? _save : null,
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}
