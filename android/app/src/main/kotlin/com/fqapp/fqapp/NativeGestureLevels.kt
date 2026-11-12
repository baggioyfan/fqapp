package com.fqapp.fqapp

import kotlin.math.roundToInt

/**
 * 分屏播放页上下滑手势的档位换算。
 *
 * 只做纯计算，不碰任何 Android 对象，便于在 JVM 单测里覆盖各 ROM 的量程差异。
 */
object NativeGestureLevels {
    /**
     * 窗口亮度下限。
     *
     * 0 是「本窗口最暗」，不是关屏 —— `screenBrightness` 里 **-1 才是跟随系统**，
     * 0 只是把背光压到面板的低端，画面仍然可见。以前压在 0.02，暗环境里偏亮，
     * 用户拉到底还刺眼，所以放开到 0（与 Dart 侧 `_readerBrightnessFloor` 同一个值）。
     */
    const val BRIGHTNESS_FLOOR = 0f

    /**
     * `Settings.System.SCREEN_BRIGHTNESS` 的原始值按面板量程归一化。
     *
     * 标准量程是 0..255，但 ColorOS 等 12bit 面板会写入 0..4095；一律按
     * 255 归一化会把 4095 读成 1600%，夹完后亮度起点永远停在 100%。
     */
    fun normaliseBrightness(raw: Int): Float {
        val value = raw.coerceAtLeast(0)
        val scale = when {
            value <= 255 -> 255f
            value <= 1023 -> 1023f
            value <= 2047 -> 2047f
            else -> 4095f
        }
        return (value / scale).coerceIn(BRIGHTNESS_FLOOR, 1f)
    }

    /** 档位下标 → 0..1 百分比。 */
    fun volumeFraction(index: Int, maxIndex: Int): Double {
        if (maxIndex <= 0) return 0.0
        return index.coerceIn(0, maxIndex).toDouble() / maxIndex
    }

    /** 0..1 百分比 → 档位下标（四舍五入，和系统音量面板同一取整）。 */
    fun volumeIndex(value: Float, maxIndex: Int): Int {
        if (maxIndex <= 0) return 0
        return (value.coerceIn(0f, 1f) * maxIndex).roundToInt()
    }
}
