package com.fqapp.fqapp

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

// Note: .agents/notes/implemented/feature/2026-10-15-system-tts.md
// One engine belongs to the app listening session, never to an Activity/page.
class SystemTtsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var tts: TextToSpeech? = null
    private var pending: MethodChannel.Result? = null
    private var timeout: Runnable? = null
    private var generation = 0
    private var activeId: String? = null
    // Every utterance the engine still owns. The reader queues a sentence ahead,
    // so callbacks can arrive for more than one id at a time.
    private val liveIds = mutableSetOf<String>()
    private var ready = false
    private var focusRequest: AudioFocusRequest? = null
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var focusEpoch = 0
    // 电话等临时抢焦点时置位：焦点交还（GAIN）后通知 Dart 自动续播。
    // 永久丢失（LOSS）走 interrupt 全停，不需要这个标记。
    private var focusTransient = false
    // 蓝牙耳机/锁屏的按键路由：TTS 听书没有前台服务，用插件内注册的
    // MediaSession 承接（进程活着它就有效，与朗读会话同生命周期）。
    private var mediaSession: MediaSessionCompat? = null
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private val audio get() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) interrupt()
        }
    }

    private fun interrupt() {
        val id = activeId
        stop()
        // Also cancels a Dart play intent while text or engine is loading.
        sink?.success(mapOf("type" to "interrupted", "id" to id))
    }

    /**
     * 焦点被临时抢走（来电、导航提示）时只停朗读，不清 epoch、不弃焦点：
     * 系统在对方放完时会发 GAIN，我们据此通知 Dart 自动续播。
     * 走 [stop] 的话焦点已交还，GAIN 永远不会再来，电话后就永远停在暂停态。
     */
    private fun transientPause() {
        focusTransient = true
        val id = activeId
        activeId = null
        liveIds.clear()
        try { tts?.stop() } catch (_: Exception) { }
        syncMediaState(false)
        sink?.success(mapOf("type" to "interrupted", "id" to id))
    }

    /** 蓝牙耳机/锁屏按键与系统媒体卡片的路由会话。 */
    private fun ensureMediaSession(): MediaSessionCompat {
        mediaSession?.let { return it }
        val session = MediaSessionCompat(context, "fqapp_system_tts")
        session.setCallback(object : MediaSessionCompat.Callback() {
            // 耳机单键是 PLAY/PAUSE 语义二选一，朗读会话只有"读/不读"两态，
            // 统一交 toggle 处理；STOP 交给 Dart 暂停会话。
            override fun onPlay() {
                sink?.success(mapOf("type" to "media", "action" to "playPause"))
            }

            override fun onPause() {
                sink?.success(mapOf("type" to "media", "action" to "playPause"))
            }

            override fun onStop() {
                sink?.success(mapOf("type" to "media", "action" to "stop"))
            }
        })
        // 蓝牙按键路由的资格证：没有它系统经常把按键丢给别的应用或直接丢弃。
        session.setMediaButtonReceiver(FqMediaButtonReceiver.mediaButtonPendingIntent(context))
        session.isActive = true
        mediaSession = session
        return session
    }

    private fun syncMediaState(playing: Boolean) {
        // 保活服务（ListenKeepAliveService，系统朗读在「后台听书与保活」开启时
        // 会借它挂通知）自带一个活跃媒体会话，通知按钮与蓝牙按键都由它承接。
        // 此时若再激活本插件的裸会话，系统就有两个活跃会话可选，按键路由在
        // 两者之间摇摆——实测蓝牙时灵时不灵。让路：服务在跑就不建、已建的释放。
        if (ListenKeepAliveService.isRunning) {
            mediaSession?.let {
                it.isActive = false
                it.release()
            }
            mediaSession = null
            return
        }
        // 停止态且会话从未建过就不建：只在真的开始朗读后才接管按键路由。
        if (!playing && mediaSession == null) return
        val session = ensureMediaSession()
        val actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_STOP
        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING
                    else PlaybackStateCompat.STATE_PAUSED,
                    0L,
                    1f,
                )
                .build(),
        )
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "fqapp/system_tts")
        events = EventChannel(binding.binaryMessenger, "fqapp/system_tts_events")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        ContextCompat.registerReceiver(context, noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
    override fun onCancel(arguments: Any?) { sink = null }

    @Suppress("DEPRECATION")
    private fun engines(): List<Map<String, String>> = context.packageManager
        .queryIntentServices(Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0)
        .map { mapOf("package" to it.serviceInfo.packageName, "label" to it.loadLabel(context.packageManager).toString()) }
        .distinctBy { it["package"] }.sortedBy { it["label"] }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "engines" -> result.success(mapOf(
                    "engines" to engines(),
                    "defaultEngine" to Settings.Secure.getString(context.contentResolver, Settings.Secure.TTS_DEFAULT_SYNTH)
                ))
                "initialize" -> initialize(call, result)
                "speak" -> {
                    val text = call.argument<String>("text").orEmpty()
                    val id = call.argument<String>("id").orEmpty()
                    // Queued utterances follow the one playing; the first one of
                    // a new position replaces whatever the engine still holds.
                    val queue = call.argument<Boolean>("queue") == true
                    when {
                        !ready -> result.error("not_ready", "朗读引擎尚未就绪", null)
                        text.isBlank() || text.length > TextToSpeech.getMaxSpeechInputLength() || id.isEmpty() ->
                            result.error("invalid_text", "朗读片段为空或过长", null)
                        !requestFocus() -> result.error("audio_focus", "其他应用正在使用音频，请稍后继续", null)
                        else -> {
                            if (!queue) liveIds.clear()
                            liveIds.add(id)
                            activeId = id
                            val mode = if (queue) TextToSpeech.QUEUE_ADD else TextToSpeech.QUEUE_FLUSH
                            if (tts?.speak(text, mode, null, id) == TextToSpeech.SUCCESS) {
                                syncMediaState(true)
                                result.success(null)
                            } else {
                                liveIds.remove(id)
                                stop()
                                syncMediaState(false)
                                result.error("speak_failed", "引擎无法朗读，请检查引擎设置或网络", null)
                            }
                        }
                    }
                }
                "stop" -> { stop(); syncMediaState(false); result.success(null) }
                "shutdown" -> { shutdown(); result.success(null) }
                "settings" -> {
                    try {
                        context.startActivity(Intent("com.android.settings.TTS_SETTINGS").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    } catch (_: android.content.ActivityNotFoundException) {
                        context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            if (call.method == "initialize") shutdown()
            if (call.method == "speak") stop()
            result.error("tts_failed", "系统朗读不可用，请检查引擎设置后重试", null)
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        shutdown()
        val engine = call.argument<String>("engine")?.takeIf { it.isNotBlank() }
        val installed = engines()
        if (installed.isEmpty() || (engine != null && installed.none { it["package"] == engine })) {
            result.error("no_engine", "未找到朗读引擎，请安装或重新选择系统 TTS 引擎", null)
            return
        }
        val rate = (call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(0.5f, 3f)
        pending = result
        val token = generation
        timeout = Runnable {
            if (token == generation && pending != null) {
                finishInitError("init_timeout", "朗读引擎启动超时，请打开引擎应用检查配置")
            }
        }.also { main.postDelayed(it, 15000) }
        try {
            tts = TextToSpeech(context, { status ->
                // OnInit may be synchronous on a failed bind; defer until tts is assigned.
                main.post {
                    if (token != generation || pending == null) return@post
                    val instance = tts
                    try {
                        if (status != TextToSpeech.SUCCESS || instance == null) {
                            finishInitError("init_failed", "朗读引擎启动失败，请检查引擎配置")
                            return@post
                        }
                        // Do not silently read Chinese with an unrelated fallback language.
                        if (instance.setLanguage(Locale.SIMPLIFIED_CHINESE) < TextToSpeech.LANG_AVAILABLE) {
                            finishInitError("language_missing", "引擎未提供中文语音，请在引擎中配置中文音色")
                            return@post
                        }
                        instance.setAudioAttributes(attributes)
                        instance.setSpeechRate(rate)
                        instance.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                            override fun onStart(id: String?) = emit(token, id, "start")
                            override fun onDone(id: String?) = emit(token, id, "done")
                            @Deprecated("Deprecated in Java")
                            override fun onError(id: String?) = emit(token, id, "error")
                            override fun onError(id: String?, errorCode: Int) = emit(token, id, "error")
                            override fun onStop(id: String?, interrupted: Boolean) = emit(token, id, "interrupted")
                            override fun onRangeStart(id: String?, start: Int, end: Int, frame: Int) =
                                emit(token, id, "range", start)
                        })
                        ready = true
                        timeout?.let(main::removeCallbacks)
                        timeout = null
                        val reply = pending
                        pending = null
                        reply?.success(TextToSpeech.getMaxSpeechInputLength())
                    } catch (_: Exception) {
                        finishInitError("init_failed", "朗读引擎配置失败，请检查中文音色")
                    }
                }
            }, engine)
        } catch (_: Exception) {
            finishInitError("init_failed", "朗读引擎启动失败，请检查引擎配置")
        }
    }

    private fun finishInitError(code: String, message: String) {
        val reply = pending
        pending = null
        shutdown()
        reply?.error(code, message, null)
    }

    private fun emit(token: Int, id: String?, type: String, start: Int = 0) {
        main.post {
            if (token != generation || id == null || !liveIds.contains(id)) return@post
            sink?.success(mapOf("type" to type, "id" to id, "start" to start))
            if (type == "start") activeId = id
            if (type == "done" || type == "error" || type == "interrupted") liveIds.remove(id)
        }
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(): Boolean {
        if (focusListener != null) return true
        val epoch = ++focusEpoch
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS ->
                    main.post { if (epoch == focusEpoch) interrupt() }
                // CAN_DUCK（导航提示等短暂压低）对语音朗读没有"压低"可言，
                // 与来电同样处理：暂停并等 GAIN 恢复。
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ->
                    main.post { if (epoch == focusEpoch) transientPause() }
                AudioManager.AUDIOFOCUS_GAIN ->
                    main.post {
                        if (epoch == focusEpoch && focusTransient) {
                            focusTransient = false
                            sink?.success(mapOf("type" to "focus_resume"))
                        }
                    }
            }
        }
        val status = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes).setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(listener, main).build().also { focusRequest = it }
            audio.requestAudioFocus(request)
        } else {
            audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        if (status == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) focusListener = listener
        else stop()
        return status == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    @Suppress("DEPRECATION")
    private fun stop() {
        focusEpoch++
        activeId = null
        liveIds.clear()
        try { tts?.stop() } catch (_: Exception) { }
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            } else {
                focusListener?.let { audio.abandonAudioFocus(it) }
            }
        } catch (_: Exception) { }
        focusRequest = null
        focusListener = null
    }

    private fun shutdown() {
        generation++
        timeout?.let(main::removeCallbacks)
        timeout = null
        val reply = pending
        pending = null
        reply?.error("cancelled", "已取消启动朗读", null)
        stop()
        focusTransient = false
        mediaSession?.let {
            it.isActive = false
            it.release()
        }
        mediaSession = null
        ready = false
        try { tts?.shutdown() } catch (_: Exception) { }
        tts = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        shutdown()
        context.unregisterReceiver(noisyReceiver)
        sink = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
