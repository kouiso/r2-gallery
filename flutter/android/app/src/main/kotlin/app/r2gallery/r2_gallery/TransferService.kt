package app.r2gallery.r2_gallery

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 転送中だけ張る dataSync のフォアグラウンドサービス（KMP 版 TransferService と同じ）。
 * 別のアプリへ切り替えたり画面を消したりしても、アップロード・オフライン保存の処理が止められんようにする。
 */
class TransferService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        // 始める依頼と実際の onStartCommand の間に件数が変わっていても、最新の件数で出す
        val notification = buildNotification(this, waiting)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // 転送の処理は Flutter の画面側で動いている。プロセスごと作り直されても続きは次の起動で台帳から再開するので、
        // 中身の無いサービスだけを OS に立て直させない
        return START_NOT_STICKY
    }

    /**
     * Android 15（API 35）から、dataSync の前面サービスは 24 時間あたり計 6 時間で OS がここを呼ぶ。
     * 呼ばれてすぐ止めないとアプリごと ForegroundServiceDidNotStopInTimeException で落とされるので、
     * 通知を残さず止める。Dart の転送は転送の記録に残り、次に開いた時に戻る。
     * Android 14 以前や dataSync 以外では呼ばれない（API 34 の onTimeout(int) は shortService 専用で使わない）
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        // 止めた後の update が通知を出し直さないよう、先に落としておく
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 最近使ったアプリから消されても、転送中はエンジン（SharedEngine）が残って Dart の転送が続く。
        // 終われば Dart 側が止めに来るので、ここではサービスを止めない
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "transfers"
        private const val NOTIFICATION_ID = 42
        private const val ACTION_STOP = "app.r2gallery.transfer.STOP"

        /** 設定で待っているだけの件数。1 以上なら動いている行は無く、通知を待機の文言にする */
        @Volatile
        private var waiting = 0

        private fun ensureChannel(context: Context) {
            // 通知チャンネルは Android 8.0 から。それより前はチャンネル無しで出る
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL) != null) return
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "転送", NotificationManager.IMPORTANCE_LOW),
            )
        }

        private fun buildNotification(context: Context, waiting: Int): Notification {
            ensureChannel(context)
            // 動いている行が 1 件でもあれば Dart は 0 を渡す。待っている行だけの時だけ待機の文言にする
            val title = if (waiting > 0) "Wi‑Fi接続待ち" else "転送中"
            val text = if (waiting > 0) {
                "${waiting}件の転送が Wi‑Fi を待っています"
            } else {
                "アップロード・ダウンロードを実行しています"
            }
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(
                    PendingIntent.getActivity(
                        context,
                        0,
                        Intent(context, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
                .build()
        }

        /** 転送中か（サービスが前面で動いているか）。画面を閉じた時にエンジンを残すかの目安。 */
        @Volatile
        var running = false
            private set

        fun start(context: Context, waiting: Int) {
            this.waiting = waiting
            ContextCompat.startForegroundService(context, Intent(context, TransferService::class.java))
        }

        /**
         * 張ったままの間に待機の件数だけ変わった時の知らせ。startForegroundService は呼ばず、
         * 同じ NOTIFICATION_ID へ notify して文言だけ替える（裏から呼び直すと Android 12 以降の起動制限に当たり得る）。
         * 張っていない時（始める依頼の途中・時間切れの後）は通知を出さず、件数だけ覚えて次の onStartCommand で使う
         */
        fun update(context: Context, waiting: Int) {
            this.waiting = waiting
            if (!running) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            manager?.notify(NOTIFICATION_ID, buildNotification(context, waiting))
        }

        fun stop(context: Context) {
            // サービスの onDestroy は後から届く。止めると決めた時点で転送中ではないとみなし、エンジンを畳む判断を遅らせない
            running = false
            // 動いていないサービスへ startService で止めに行くと、裏からの起動制限に掛かることがある
            context.stopService(Intent(context, TransferService::class.java))
        }
    }
}
