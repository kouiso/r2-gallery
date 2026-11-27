package app.r2gallery.r2_gallery

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
 * 回線は stateOf の Map（online / wifi / metered / dataSaver）で流す。Wi‑Fi 限定の設定（#27）が
 * 「使えるか」だけでは決められないため。Dart は古い bool も読む。
 */
object TransferBridge {
    private var askedNotifications = false
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var dataSaverReceiver: BroadcastReceiver? = null

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
                    events.success(stateOf(cm))
                    val cb = object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) {
                            // Android 7 では onCapabilitiesChanged が続く保証が無いので、ここでも流す。
                            // 回線の様子がまだ取れない時は今まで通り「繋がった」だけを流す（Dart は種類不明のオンラインとして読む）
                            val caps = cm.getNetworkCapabilities(network)
                            val state: Any = if (caps == null) true else stateOf(cm, caps)
                            main.post { events.success(state) }
                        }

                        // Wi‑Fi とモバイル回線の切り替えや従量制の変化はここで届く
                        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                            val state = stateOf(cm, networkCapabilities)
                            main.post { events.success(state) }
                        }

                        override fun onLost(network: Network) {
                            main.post { events.success(stateOf(cm)) }
                        }
                    }
                    callback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
                    callback = cb
                    cm.registerDefaultNetworkCallback(cb)
                    // 省データ設定の切り替えは NetworkCallback では届かない。登録した受け手にだけ届く知らせで拾う
                    unregisterDataSaver(app)
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context, intent: Intent) {
                            events.success(stateOf(cm))
                        }
                    }
                    try {
                        ContextCompat.registerReceiver(
                            app,
                            receiver,
                            IntentFilter(ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED),
                            ContextCompat.RECEIVER_NOT_EXPORTED,
                        )
                        dataSaverReceiver = receiver
                    } catch (_: Exception) {
                        // 登録できなくても省データの切り替えが次の回線の変化まで遅れるだけ。転送は止めない
                    }
                }

                override fun onCancel(arguments: Any?) {
                    val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                    callback?.let { cb -> cm?.let { runCatching { it.unregisterNetworkCallback(cb) } } }
                    callback = null
                    unregisterDataSaver(app)
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
        unregisterDataSaver(context.applicationContext)
    }

    private fun unregisterDataSaver(app: Context) {
        val receiver = dataSaverReceiver ?: return
        dataSaverReceiver = null
        runCatching { app.unregisterReceiver(receiver) }
    }

    /** 今の既定の回線の様子。既定の回線が無ければオフライン。 */
    private fun stateOf(cm: ConnectivityManager): Map<String, Boolean> =
        stateOf(cm, cm.activeNetwork?.let { cm.getNetworkCapabilities(it) })

    private fun stateOf(cm: ConnectivityManager, caps: NetworkCapabilities?): Map<String, Boolean> {
        // 省データ設定は従量制の回線で裏の通信を止める。読めなければ効いていない扱いにし、転送を止めない
        val dataSaver = runCatching {
            cm.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
        }.getOrDefault(false)
        if (caps == null) {
            return mapOf("online" to false, "wifi" to false, "metered" to false, "dataSaver" to dataSaver)
        }
        return mapOf(
            "online" to caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
            // 設定の名前「Wi‑Fi接続時のみ」に合わせ、従量制かどうかは問わない（有線も Wi‑Fi と同じに扱う）
            "wifi" to (
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                ),
            "metered" to !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
            "dataSaver" to dataSaver,
        )
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
