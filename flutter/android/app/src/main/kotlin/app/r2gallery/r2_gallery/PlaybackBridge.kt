package app.r2gallery.r2_gallery

import android.app.Activity
import android.app.AppOpsManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.util.Rational
import androidx.core.content.ContextCompat
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.SettableFuture
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.TimeoutException

data class PlaybackSnapshot(
    val session: String,
    val playing: Boolean = false,
    val position: Long = 0,
    val duration: Long = 0,
    val buffering: Boolean = false,
    val ended: Boolean = false,
    val speed: Float = 1f,
)

/** メディア情報は匿名の状態だけ。URLやdecoderをサービスへ複製しない。 */
object PlaybackBridge {
    private var host: WeakReference<Activity>? = null
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private val handler = Handler(Looper.getMainLooper())
    var snapshot: PlaybackSnapshot? = null
        private set
    val hasSession: Boolean get() = snapshot != null
    private var startingService = false
    // Dart が「ホームへ出たら自動で小窓に入ってよい」と知らせている間だけ true。
    private var pipArmed = false
    private var pipAspect: IntArray = intArrayOf(16, 9)
    // clear の後に小窓の中で終わっても、閉じる通知を Dart へ届けるために控える。
    private var pipSession: String? = null
    // 小窓の再生／一時停止ボタンが押された放送を受ける。小窓にいる間だけ登録する。
    private var pipReceiver: BroadcastReceiver? = null
    // 直近に OS へ渡した小窓の設定。同じ内容なら position の更新ごとに渡し直さない。
    private var lastPipParamsKey: String? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        this.context = context.applicationContext
        channel = MethodChannel(messenger, "app.r2gallery/playback").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                val session = call.argument<String>("session")
                if (call.method == "bind") {
                    val id = call.argument<Number>("playerId")?.toLong()
                    if (session == null || id == null || id < 0) {
                        result.error("invalid_player", "再生器を確認できません", null)
                    } else {
                        snapshot = PlaybackSnapshot(session)
                        pipArmed = false
                        pipSession = null
                        result.success(mapOf("pip" to pipSupported(), "background" to true))
                    }
                    return@setMethodCallHandler
                }
                // 小窓の中で再生が終わると snapshot は null になる。その後のロック・接続変更でも
                // 小窓ごと閉じる必要があるので、exitPip だけは小窓の session も受ける。
                val accepted = if (call.method == "exitPip") {
                    PipPolicy.acceptsExit(session, snapshot?.session, pipSession)
                } else session == snapshot?.session
                if (session == null || !accepted) {
                    result.success(if (call.method == "enterPip") false else null)
                    return@setMethodCallHandler
                }
                try {
                    when (call.method) {
                        "update" -> {
                            val speed = call.argument<Number>("speed")?.toFloat() ?: 1f
                            snapshot = PlaybackSnapshot(
                                session, call.argument<Boolean>("playing") == true,
                                (call.argument<Number>("position")?.toLong() ?: 0).coerceAtLeast(0),
                                (call.argument<Number>("duration")?.toLong() ?: 0).coerceAtLeast(0),
                                call.argument<Boolean>("buffering") == true,
                                call.argument<Boolean>("ended") == true,
                                if (speed.isFinite() && speed > 0) speed else 1f,
                            )
                            publish()
                            // 一時停止の知らせが Dart から遅れても、native の再生状態で自動で入るのを止める
                            applyPipParams()
                            result.success(null)
                        }
                        "clear" -> {
                            pipSession = if (host?.get()?.isInPictureInPictureMode == true) session else null
                            snapshot = null
                            pipArmed = false
                            applyPipParams()
                            PlaybackService.instance?.clearSession()
                            startingService = false
                            SharedEngine.releaseIfDetached(context)
                            result.success(null)
                        }
                        "enterPip" -> {
                            val activity = host?.get()
                            pipAspect = PipPolicy.aspect(
                                call.argument<Number>("videoWidth")?.toInt() ?: 0,
                                call.argument<Number>("videoHeight")?.toInt() ?: 0,
                            )
                            val accepted = if (Build.VERSION.SDK_INT >= 26 && activity != null && pipSupported()) {
                                activity.enterPictureInPictureMode(pipParams(false)).also { lastPipParamsKey = null }
                            } else false
                            result.success(accepted)
                        }
                        "armPip" -> {
                            pipArmed = call.argument<Boolean>("armed") == true
                            pipAspect = PipPolicy.aspect(
                                call.argument<Number>("width")?.toInt() ?: 0,
                                call.argument<Number>("height")?.toInt() ?: 0,
                            )
                            applyPipParams()
                            result.success(null)
                        }
                        "pipPermitted" -> result.success(pipPermitted())
                        "openPipSettings" -> {
                            openPipSettings()
                            result.success(null)
                        }
                        "exitPip" -> {
                            val activity = host?.get()
                            // 認証ロック時に小窓を残さず、利用者の画面を強制的に前面へ戻さない。
                            if (Build.VERSION.SDK_INT >= 26 && activity?.isInPictureInPictureMode == true) {
                                // finish() で pipChanged(false) が届く保証は無いので、受信側と小窓の記録をここで外す
                                unregisterPipReceiver()
                                pipSession = null
                                activity.finish()
                            }
                            result.success(null)
                        }
                        "visibility" -> result.success(null)
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("playback_unavailable", "システムの再生操作を利用できません", null)
                }
            }
        }
    }

    fun attach(activity: Activity) {
        host = WeakReference(activity)
        // 別の Activity には前の設定が残っていないので、必ず渡し直す
        lastPipParamsKey = null
    }

    fun detach(activity: Activity) {
        if (host?.get() !== activity) return
        host = null
        // Activity が終わる時は小窓の受信側も残さない
        if (activity.isFinishing) unregisterPipReceiver()
        if (activity.isFinishing && !activity.isChangingConfigurations) command("close")
    }

    /**
     * [restoring] は小窓が閉じた時点の画面の状態で native が決めた値（true=元に戻す、false=×）。
     * 時間差で見分けると端末の速さに左右されるため、Dart には結果だけを渡す。
     */
    fun pipChanged(active: Boolean, restoring: Boolean? = null) {
        // セッションが無くても受信側の登録は小窓の出入りに合わせて外す（取りこぼして残さない）
        if (active) registerPipReceiver() else unregisterPipReceiver()
        val session = snapshot?.session ?: pipSession ?: return
        val arguments = mutableMapOf<String, Any>("session" to session, "active" to active)
        if (!active && restoring != null) arguments["restoring"] = restoring
        if (!active) pipSession = null
        channel?.invokeMethod("pipChanged", arguments)
    }

    /** API 26〜30 は OS が自動で入らないので、ホームへ出る時に自分から入る。 */
    fun userLeaveHint(activity: Activity) {
        if (PipPolicy.route(Build.VERSION.SDK_INT, pipSupported()) != PipPolicy.Route.USER_LEAVE_HINT) return
        val state = snapshot ?: return
        if (!PipPolicy.autoEnterAllowed(pipArmed, state.playing, state.ended)) return
        try {
            activity.enterPictureInPictureMode(pipParams(false))
            lastPipParamsKey = null
        } catch (_: Exception) {
            // OS に断られても画面にエラーは出さず、ホームへ出ただけの扱いにする。
        }
    }

    private fun pipParams(autoEnter: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(pipAspect[0], pipAspect[1]))
        if (Build.VERSION.SDK_INT >= 31) builder.setAutoEnterEnabled(autoEnter)
        builder.setActions(pipActions())
        return builder.build()
    }

    /**
     * 小窓の再生／一時停止ボタン。再生中は一時停止、それ以外は再生を出す。
     * 押した結果は Dart の command 経路（認証・ロックの猶予を通す）へそのまま渡す。
     * セッションが無い間はボタンを出さない。
     */
    private fun pipActions(): List<RemoteAction> {
        val app = context ?: return emptyList()
        val state = snapshot ?: return emptyList()
        val playing = state.playing && !state.ended
        val intent = Intent(PipPolicy.actionName(playing)).setPackage(app.packageName)
        // 再生用と一時停止用で requestCode を分け、PendingIntent が互いを上書きしないようにする
        val pending = PendingIntent.getBroadcast(
            app, if (playing) 1 else 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val label = if (playing) "一時停止" else "再生"
        val icon = Icon.createWithResource(
            app, if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
        )
        return listOf(RemoteAction(icon, label, label, pending))
    }

    private fun registerPipReceiver() {
        val app = context ?: return
        if (pipReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val action = PipPolicy.commandFor(intent.action) ?: return
                // 失敗は握る。session が無い・拒否された時はボタンが効かないだけで、再生は壊さない
                try { command(action) } catch (_: Exception) {}
            }
        }
        val filter = IntentFilter().apply {
            addAction(PipPolicy.ACTION_PLAY)
            addAction(PipPolicy.ACTION_PAUSE)
        }
        try {
            ContextCompat.registerReceiver(app, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
            pipReceiver = receiver
        } catch (_: Exception) {
            // 登録できなくてもボタンが効かないだけ。小窓自体は使える
        }
    }

    private fun unregisterPipReceiver() {
        val receiver = pipReceiver ?: return
        pipReceiver = null
        try { context?.unregisterReceiver(receiver) } catch (_: Exception) {}
    }

    /**
     * API 31 以上は OS が自動で入るので、入ってよい間だけ有効にしておく。
     * 小窓のボタンの絵は API 26〜30 でも入った後に差し替える必要があるため、対応端末なら全経路で渡す
     * （setAutoEnterEnabled は pipParams 側で API 31 以上に限っている）。
     */
    private fun applyPipParams() {
        val activity = host?.get() ?: return
        if (PipPolicy.route(Build.VERSION.SDK_INT, pipSupported()) == PipPolicy.Route.NONE) return
        val state = snapshot
        val auto = PipPolicy.autoEnterAllowed(pipArmed, state?.playing == true, state?.ended == true)
        val showsPause = state?.playing == true && state.ended != true
        // 位置の更新ごとに OS へ渡し直さない。比・自動・ボタンの絵が変わった時だけ渡す
        val key = "${pipAspect[0]}/${pipAspect[1]}:$auto:${state != null}:$showsPause"
        if (key == lastPipParamsKey) return
        try {
            activity.setPictureInPictureParams(pipParams(auto))
            lastPipParamsKey = key
        } catch (_: Exception) {
            // 設定できなくても再生は止めない。自動で入らないだけ。
        }
    }

    /** 端末の設定でこのアプリの小窓が許可されているか。調べられない時は許可の問題にしない。 */
    private fun pipPermitted(): Boolean {
        val app = context ?: return true
        if (Build.VERSION.SDK_INT < 26) return true
        return try {
            val ops = app.getSystemService(AppOpsManager::class.java) ?: return true
            ops.checkOpNoThrow(AppOpsManager.OPSTR_PICTURE_IN_PICTURE, Process.myUid(), app.packageName) ==
                AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            true
        }
    }

    private fun openPipSettings() {
        val activity = host?.get() ?: return
        val uri = Uri.fromParts("package", activity.packageName, null)
        try {
            // 小窓の設定画面の定数は SDK に公開されていないので、同じ値の文字列で開く。
            activity.startActivity(Intent("android.settings.PICTURE_IN_PICTURE_SETTINGS", uri))
        } catch (_: ActivityNotFoundException) {
            // 小窓専用の画面が無い端末ではアプリ情報へ出す。
            try {
                activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri))
            } catch (_: ActivityNotFoundException) {
            }
        }
    }

    private fun pipSupported(): Boolean = Build.VERSION.SDK_INT >= 26 &&
        host?.get()?.packageManager?.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) == true

    private fun publish() {
        val state = snapshot ?: return
        val service = PlaybackService.instance
        if (service != null) {
            service.applySnapshot(state)
        } else if (state.playing && !startingService) {
            startingService = true
            try {
                ContextCompat.startForegroundService(context!!, Intent(context, PlaybackService::class.java))
            } catch (error: Exception) {
                startingService = false
                throw error
            }
        }
    }

    fun serviceDestroyed(service: PlaybackService) {
        if (PlaybackService.instance === service) startingService = false
    }

    fun command(action: String, position: Long? = null): ListenableFuture<Any?> {
        val done = SettableFuture.create<Any?>()
        val session = snapshot?.session
        val bridge = channel
        if (session == null || bridge == null) {
            done.setException(IllegalStateException("No active playback session"))
            return done
        }
        val arguments = mutableMapOf<String, Any>("session" to session, "action" to action)
        if (position != null) arguments["position"] = position
        bridge.invokeMethod("command", arguments, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (result == true) done.set(null)
                else done.setException(IllegalStateException("Playback command rejected"))
            }
            override fun error(code: String, message: String?, details: Any?) {
                done.setException(IllegalStateException("Playback command unavailable"))
            }
            override fun notImplemented() {
                done.setException(IllegalStateException("Playback command unsupported"))
            }
        })
        handler.postDelayed({
            if (!done.isDone) done.setException(TimeoutException("Playback command expired"))
        }, 10_000)
        return done
    }

    fun release() {
        unregisterPipReceiver()
        snapshot = null
        channel?.setMethodCallHandler(null)
        channel = null
        host = null
        startingService = false
    }
}
