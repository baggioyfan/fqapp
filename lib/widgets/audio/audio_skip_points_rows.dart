import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../services/audio_playback_choice.dart';
import '../home/home_design.dart';

/// 更多面板里的「跳过片头 / 跳过片尾」两行。
///
/// 官方 `du`/`dq` 是「跳过片头 / 跳过片尾」，`e8`/`e9`/`e_` 是设置成功的提示，
/// 说明这是**按书**保存的偏好。默认 0 秒（不跳）。
class AudioSkipPointsRows extends StatelessWidget {
  final AudioSkipPoints points;
  final ValueChanged<AudioSkipPoints> onChanged;

  const AudioSkipPointsRows({
    super.key,
    required this.points,
    required this.onChanged,
  });

  /// 可选秒数档位。
  static const options = <int>[0, 10, 15, 20, 30];
  static const _maxSeconds = 24 * 60 * 60;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _row(
          context: context,
          palette: palette,
          key: const Key('audio_skip_intro'),
          icon: LucideIcons.skip_forward,
          title: '跳过片头',
          seconds: points.introSeconds,
          onPicked: (value) => onChanged(
            AudioSkipPoints(
              introSeconds: value,
              outroSeconds: points.outroSeconds,
            ),
          ),
        ),
        _row(
          context: context,
          palette: palette,
          key: const Key('audio_skip_outro'),
          icon: LucideIcons.skip_back,
          title: '跳过片尾',
          seconds: points.outroSeconds,
          onPicked: (value) => onChanged(
            AudioSkipPoints(
              introSeconds: points.introSeconds,
              outroSeconds: value,
            ),
          ),
        ),
      ],
    );
  }

  Widget _row({
    required BuildContext context,
    required HomePalette palette,
    required Key key,
    required IconData icon,
    required String title,
    required int seconds,
    required ValueChanged<int> onPicked,
  }) {
    return ListTile(
      key: key,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: palette.ink.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: palette.ink),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
          color: palette.ink,
        ),
      ),
      subtitle: Text(
        seconds == 0 ? '不跳过' : '$title $seconds 秒',
        style: TextStyle(fontSize: 12.5, color: palette.muted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            seconds == 0 ? '关闭' : '$seconds 秒',
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
          const SizedBox(width: 2),
          Icon(LucideIcons.chevron_right, size: 14, color: palette.muted),
        ],
      ),
      onTap: () => _pick(context, title, seconds, onPicked),
    );
  }

  Future<void> _pick(
    BuildContext context,
    String title,
    int current,
    ValueChanged<int> onPicked,
  ) async {
    var picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(title)),
              for (final value in options)
                ListTile(
                  title: Text(value == 0 ? '关闭（不跳过）' : '$value 秒'),
                  trailing: value == current
                      ? const Icon(LucideIcons.check, color: HomePalette.accent)
                      : null,
                  onTap: () => Navigator.pop(context, value),
                ),
              ListTile(
                title: const Text('自定义秒数'),
                subtitle: options.contains(current) ? null : Text('$current 秒'),
                trailing: options.contains(current)
                    ? null
                    : const Icon(LucideIcons.check, color: HomePalette.accent),
                onTap: () => Navigator.pop(context, -1),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == -1) {
      if (!context.mounted) return;
      picked = await _customSeconds(context, title, current);
    }
    if (picked == null) return;
    onPicked(picked);
  }

  Future<int?> _customSeconds(BuildContext context, String title, int current) {
    final formKey = GlobalKey<FormState>();
    var input = '$current';
    return showDialog<int>(
      context: context,
      builder: (context) {
        void submit() {
          if (formKey.currentState!.validate()) {
            Navigator.pop(context, int.parse(input.trim()));
          }
        }

        return AlertDialog(
          title: Text('$title（秒）'),
          scrollable: true,
          content: Form(
            key: formKey,
            child: TextFormField(
              initialValue: input,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '秒数',
                helperText: '0–$_maxSeconds 秒，0 表示不跳过',
                suffixText: '秒',
              ),
              onChanged: (value) => input = value,
              validator: (value) {
                final seconds = int.tryParse(value?.trim() ?? '');
                if (seconds == null || seconds < 0 || seconds > _maxSeconds) {
                  return '请输入 0–$_maxSeconds 的整数';
                }
                return null;
              },
              onFieldSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(onPressed: submit, child: const Text('确定')),
          ],
        );
      },
    );
  }
}
