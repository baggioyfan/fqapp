part of '../reader_page.dart';

/// 亮度下限：**0 就是面板最暗**，不再像以前那样停在 2%。
///
/// 以前这里（和原生 `NativeGestureLevels.BRIGHTNESS_FLOOR`）都把下限压在
/// 0.02，理由是「窗口亮度 0 等于关屏」。实际上 Android 的
/// `WindowManager.LayoutParams.screenBrightness` 里 **-1 才是「跟随系统」**，
/// 0 只是「本窗口最暗」——背光压到底，画面仍然可见（极暗环境里比 2% 更不刺眼）。
/// 想看回正常亮度上滑即可，手势在 Flutter 层，屏幕再暗也照样响应。
///
/// 放顶层而不是 extension 里：Dart 的 extension 不许声明 static 成员。
const double _readerBrightnessFloor = 0;

/// 翻页模式下上下滑调亮度。
///
/// 手感与播放器竖滑一致：上滑变亮、下滑变暗，屏高约六成走完整个量程；
/// 拖动中只下发窗口亮度并更新浮层，**松手才落偏好** —— 每帧写一次
/// SharedPreferences 会把拖动卡出掉帧。
///
/// 只在翻页模式挂：滚动模式里上下滑是滚正文，抢过来就没法读书了。
/// 桌面没有这条原生桥（[_deviceAvailable] 为 false），手势自动失效。
extension _ReaderPageBrightness on _ReaderPageState {
  /// 当前真正生效的亮度：跟随系统时取系统值，否则取阅读偏好值。
  double get _currentBrightness => _preferences.followSystemBrightness
      ? (_deviceStatus.systemBrightness ?? _preferences.brightness)
      : _preferences.brightness;

  void _onBrightnessDragStart(DragStartDetails details) {
    if (!_deviceAvailable) return;
    _brightnessGestureBase = _currentBrightness;
    _brightnessGestureStartY = details.globalPosition.dy;
    _brightnessGestureSent = null;
    // 清掉上一轮的残留：轻点（没有 update 就 end）不能拿旧值去写偏好。
    _brightnessHud.value = null;
  }

  void _onBrightnessDragUpdate(DragUpdateDetails details) {
    final base = _brightnessGestureBase;
    final startY = _brightnessGestureStartY;
    if (base == null || startY == null) return;
    // 位移换算成亮度：屏高六成走完整量程（800dp 的机器约 480dp 从最暗到最亮）。
    // 下限夹一下，免得极端小的窗口把量程压成几像素、一碰就跳到底。
    final span = (MediaQuery.sizeOf(context).height * .6).clamp(
      240.0,
      double.infinity,
    );
    final value = (base + (startY - details.globalPosition.dy) / span).clamp(
      _readerBrightnessFloor,
      1.0,
    );
    _brightnessHud.value = value;
    // 1% 节流：拖动一帧一次 MethodChannel 掉帧会直接反映在文字滚动上。
    final sent = _brightnessGestureSent;
    if (sent != null && (value - sent).abs() < .01) return;
    _brightnessGestureSent = value;
    unawaited(_device.setBrightness(followSystem: false, brightness: value));
  }

  void _onBrightnessDragEnd(DragEndDetails _) => _finishBrightnessDrag();

  void _onBrightnessDragCancel() => _finishBrightnessDrag();

  void _finishBrightnessDrag() {
    final sent = _brightnessGestureSent;
    final value = _brightnessHud.value;
    _brightnessGestureBase = null;
    _brightnessGestureStartY = null;
    _brightnessGestureSent = null;
    // 只移动了几像素、没到 1% 门槛的手势不算调整：别拿它改偏好。
    if (sent == null || value == null) return;
    // 落偏好并补齐终点值：拖动中的 1% 节流可能吞掉最后一档。
    // 浮层不在这里清空，交给它自己的自动隐藏，松手后还能看一眼最终亮度。
    _changeBrightness(value);
  }
}
