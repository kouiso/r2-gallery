package app.r2gallery.r2_gallery

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 転送キューと端末をつなぐ口。サービスの開始・停止と、既定の回線の変化を Dart へ流す
 * （KMP 版 ConnectivityMonitor と同じく既定の回線だけを見る。別経路が生えただけで「繋がった」にしない）。
 */
object TransferBridge {
    private var askedNotifications = false
    private var callback: ConnectivityManager.NetworkCallback? = null

    fun register(activity: Activity, messenger: BinaryMessenger) {
        val app = activity.applicationContext
        MethodChannel(messenger, "app.r2gallery/transfer").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    requestNotificationsOnce(activity)
                    try {
                        TransferService.start(app)
                        result.success(null)
                    } catch (e: IllegalStateException) {
                        // Android 12 以降、裏からはサービスを始められない。前面に戻った時の次の切り替えで張り直す
                        result.error("start_failed", e.message, null)
                    }
                }
                "stop" -> {
                    TransferService.stop(app)
                    result.success(null)
                    // 画面を消された後に転送が終わったなら、残しておいたエンジンもここで畳む
                    SharedEngine.releaseIfDetached(app)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "app.r2gallery/connectivity").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                    if (cm == null) {
                        events.success(true)
                        return
                    }
                    val main = Handler(Looper.getMainLooper())
                    events.success(currentlyOnline(cm))
                    val cb = object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) {
                            main.post { events.success(true) }
                        }

                        override fun onLost(network: Network) {
                            main.post { events.success(currentlyOnline(cm)) }
                        }
                    }
                    callback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
                    callback = cb
                    cm.registerDefaultNetworkCallback(cb)
                }

                override fun onCancel(arguments: Any?) {
                    val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                    callback?.let { cb -> cm?.let { runCatching { it.unregisterNetworkCallback(cb) } } }
                    callback = null
                }
            },
        )
    }

    /** エンジンを畳む時（Dart 側の処理も止まる時）に、通知つきのサービスと回線の見張りを残さない。 */
    fun release(context: Context) {
        TransferService.stop(context.applicationContext)
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        callback?.let { cb -> cm?.let { runCatching { it.unregisterNetworkCallback(cb) } } }
        callback = null
    }

    private fun currentlyOnline(cm: ConnectivityManager): Boolean {
        val net = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(net) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // Android 13 以降は通知の許可が無いと転送中の通知が出ない（転送自体は続く）。最初の転送の時に1回だけ聞く
    private fun requestNotificationsOnce(activity: Activity) {
        if (askedNotifications || Build.VERSION.SDK_INT < 33) return
        // 画面を消された後の転送からは聞けない。次に画面がある時の転送で聞く
        if (activity.isFinishing || activity.isDestroyed) return
        askedNotifications = true
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(activity, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4201)
    }
}
