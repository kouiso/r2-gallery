package app.r2gallery.r2_gallery

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
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
                        result.success(mapOf("pip" to pipSupported(), "background" to true))
                    }
                    return@setMethodCallHandler
                }
                if (session == null || session != snapshot?.session) {
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
                            result.success(null)
                        }
                        "clear" -> {
                            snapshot = null
                            PlaybackService.instance?.clearSession()
                            startingService = false
                            SharedEngine.releaseIfDetached(context)
                            result.success(null)
                        }
                        "enterPip" -> {
                            val activity = host?.get()
                            val ratio = call.argument<Number>("aspectRatio")?.toDouble() ?: 16.0 / 9
                            val aspect = if (ratio.isFinite()) ratio.coerceIn(0.42, 2.39) else 16.0 / 9
                            val accepted = if (Build.VERSION.SDK_INT >= 26 && activity != null && pipSupported()) {
                                activity.enterPictureInPictureMode(
                                    PictureInPictureParams.Builder()
                                        .setAspectRatio(Rational((aspect * 1000).toInt(), 1000))
                                        .build(),
                                )
                            } else false
                            result.success(accepted)
                        }
                        "exitPip" -> {
                            val activity = host?.get()
                            // 認証ロック時に小窓を残さず、利用者の画面を強制的に前面へ戻さない。
                            if (Build.VERSION.SDK_INT >= 26 && activity?.isInPictureInPictureMode == true) {
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

    fun attach(activity: Activity) { host = WeakReference(activity) }

    fun detach(activity: Activity) {
        if (host?.get() !== activity) return
        host = null
        if (activity.isFinishing && !activity.isChangingConfigurations) command("close")
    }

    fun pipChanged(active: Boolean) {
        val session = snapshot?.session ?: return
        channel?.invokeMethod("pipChanged", mapOf("session" to session, "active" to active))
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
        snapshot = null
        channel?.setMethodCallHandler(null)
        channel = null
        host = null
        startingService = false
    }
}
