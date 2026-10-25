package com.fqapp.fqapp

import android.app.Activity
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 全屏播放时左半屏竖滑调亮度。
 *
 * 只改当前 Activity 的窗口亮度（`WindowManager.LayoutParams.screenBrightness`），
 * 不写系统设置、也不需要任何权限；[end] 把窗口属性还原成进入前的值（通常是
 * -1 = 跟随系统），所以退出全屏或离开播放页都不会留下残留亮度。
 *
 * 会话归属与「离开还原」复用 [ReaderBrightnessSession]：它已经处理了「谁开的
 * 谁关」以及「离开时还原原值」，阅读器与播放页各持一个实例，靠 owner 隔离。
 */
class PlayerDisplayPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var window: ReaderBrightnessSession.Window? = null
    private val brightness = ReaderBrightnessSession()
    private var session: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        brightness.clear()
        window = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        val target = binding.activity.window
        window = object : ReaderBrightnessSession.Window {
            override var brightness: Float
                get() = target.attributes.screenBrightness
                set(value) {
                    val attributes = target.attributes
                    attributes.screenBrightness = value
                    target.attributes = attributes
                }
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // 窗口随 Activity 重建，onReattached 会拿到新的那个。
        val current = session
        if (current != null) brightness.suspend(current)
        window = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        brightness.clear()
        session = null
        window = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("session")
        if (id.isNullOrEmpty()) {
            result.error("BAD_SESSION", "播放会话已结束", null)
            return
        }
        val target = window
        if (target == null) {
            result.error("NO_ACTIVITY", "播放界面尚未就绪", null)
            return
        }
        when (call.method) {
            "begin" -> {
                // attach 只会记下窗口，不改值；open 才记录「进入前的原值」并应用。
                brightness.attach(target)
                session = id
                val current = currentBrightness()
                brightness.open(id, current)
                result.success(current.toDouble())
            }
            "setBrightness" -> {
                val raw = call.argument<Number>("brightness")?.toFloat()
                if (raw == null || !raw.isFinite() || raw !in MIN..MAX) {
                    result.error("BAD_BRIGHTNESS", "亮度值无效", null)
                    return
                }
                result.success(brightness.update(id, raw))
            }
            "end" -> {
                brightness.close(id)
                if (session == id) session = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** 窗口已有 override 就用它，否则回落到系统设置里的亮度（0..1）。 */
    private fun currentBrightness(): Float {
        val override = window?.brightness ?: -1f
        if (override >= 0f) return override.coerceIn(MIN, MAX)
        val resolver = activity?.contentResolver
        val raw = if (resolver == null) {
            DEFAULT_SYSTEM_BRIGHTNESS
        } else {
            try {
                Settings.System.getInt(
                    resolver,
                    Settings.System.SCREEN_BRIGHTNESS,
                    DEFAULT_SYSTEM_BRIGHTNESS,
                )
            } catch (_: Exception) {
                // 个别 ROM 会限制这个读取；拿不到就给一个中间值，手势照常可用。
                DEFAULT_SYSTEM_BRIGHTNESS
            }
        }
        return (raw / 255f).coerceIn(MIN, MAX)
    }

    private companion object {
        const val CHANNEL = "fqapp/player/display"

        // 与阅读器同一个下限：2% 以下整块画面看不见，等于关了屏幕。
        const val MIN = 0.02f
        const val MAX = 1f
        const val DEFAULT_SYSTEM_BRIGHTNESS = 128
    }
}
