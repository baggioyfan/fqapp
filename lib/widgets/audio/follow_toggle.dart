import 'package:flutter/material.dart';

import '../../services/listening_session.dart';

/// 迷你栏的「跟随」开关：按一次开跟随并跳到播放位置，再按一次放开自由翻页。
///
/// 状态存在 [ListeningSession.followArmed] 上，图标由本组件自己管 —— 迷你栏
/// 整条由 OverlayEntry 重建，单独抽出来才不会被拖着整条一起刷。
///
/// 真人听书迷你栏与系统朗读迷你栏共用：两者的定位链都由阅读页注册的
/// [ListeningSession.jumpToPlaybackHandler] 承接，语义一致。
class FollowToggle extends StatefulWidget {
  const FollowToggle({super.key});

  @override
  State<FollowToggle> createState() => _FollowToggleState();
}

class _FollowToggleState extends State<FollowToggle> {
  @override
  void initState() {
    super.initState();
    // 阅读页手动翻页会退出跟随，图标得跟着变回来；迷你栏挂在 Overlay 上，
    // 只能听会话的通知。
    ListeningSession.instance.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    ListeningSession.instance.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final armed = ListeningSession.instance.followArmed;
    // 处理函数由阅读页注册/注销，按钮的可点状态得跟着它走。迷你栏挂在
    // Overlay 上、不会为这个重建，所以直接在构建里读那个 notifier：
    // 只在真的换了函数时通知一次（同值不通知），不会变成每帧重刷。
    return ValueListenableBuilder<void Function()?>(
      valueListenable: ListeningSession.instance.jumpToPlaybackHandlerListenable,
      builder: (context, handler, _) => IconButton(
        key: const ValueKey('audio-mini-jump'),
        // 点一次就跳到朗读处（不管之前开没开），长按才是停止跟随 ——
        // 之前是「点一下切开关」，已经在跟随时再点只会关掉、不会重新定位，
        // 想回到朗读处就得点两次。
        tooltip: armed ? '跟随中，点按回到朗读处；长按停止跟随' : '点按跳到朗读处并跟随',
        onPressed: handler == null
            ? null
            : () {
                ListeningSession.instance.setFollowArmed(true);
                handler();
              },
        onLongPress: armed
            ? () => ListeningSession.instance.setFollowArmed(false)
            : null,
        icon: Icon(
          armed ? Icons.gps_fixed : Icons.my_location,
          // 跟随中染主色：一眼能看出「页面正在被朗读带着走」。
          color: armed ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
    );
  }
}
