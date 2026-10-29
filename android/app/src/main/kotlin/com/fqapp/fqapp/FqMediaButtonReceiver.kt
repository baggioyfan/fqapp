package com.fqapp.fqapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.app.PendingIntent
import android.os.Build
import android.view.KeyEvent

/**
 * 蓝牙 / 有线耳机媒体按键的兜底接收器。
 *
 * 通知卡片的暂停按钮直连媒体会话所以总有效；蓝牙按键走的是另一条系统
 * 「媒体按钮路由」：只有一个活跃会话还不够，系统在挑接收者时优先认
 * 「注册了 MediaButtonReceiver 的应用」（legado 听书的蓝牙可靠正是这套，
 * 官方听书则是靠前台服务 + 常驻会话排到队首）。没有接收器时按键经常被
 * 系统直接丢掉——实测蓝牙时灵时不灵的根因。
 *
 * 收到按键后翻译成与通知按钮相同的动作名，走同一条
 * [NativePlayerPlugin.dispatchNotificationAction] 通路交给 Dart 当前注册的
 * 远程命令处理器（官方听书或系统朗读，谁在用归谁）。
 */
class FqMediaButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MEDIA_BUTTON) return
        val event = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
        } ?: return
        val action = when (event.keyCode) {
            // 播放/暂停键与线控单击都按切换处理：Dart 侧的 playPause 是 toggle，
            // 系统按会话状态补发的 PLAY/PAUSE 码落到同一个切换上结果是对的。
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            -> ListenKeepAliveService.ACTION_NAME_PLAY_PAUSE
            KeyEvent.KEYCODE_MEDIA_NEXT -> ListenKeepAliveService.ACTION_NAME_NEXT
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> ListenKeepAliveService.ACTION_NAME_PREV
            KeyEvent.KEYCODE_MEDIA_STOP -> ListenKeepAliveService.ACTION_NAME_STOP
            else -> return
        }
        NativePlayerPlugin.dispatchNotificationAction(action)
    }

    companion object {
        /**
         * 挂到媒体会话上的「媒体按钮接收者」：系统在路由蓝牙按键时据此把本应用
         * 排进候选（API 31+ 也接受广播 PendingIntent）。会话激活前设置一次。
         */
        fun mediaButtonPendingIntent(context: Context): PendingIntent =
            PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, FqMediaButtonReceiver::class.java).setAction(Intent.ACTION_MEDIA_BUTTON),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
    }
}
