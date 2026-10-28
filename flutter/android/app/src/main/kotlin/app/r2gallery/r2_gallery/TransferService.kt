package app.r2gallery.r2_gallery

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
        ensureChannel()
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("転送中")
            .setContentText("アップロード・ダウンロードを実行しています")
            .setOngoing(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // 転送の処理は Flutter の画面側で動いている。プロセスごと作り直されても続きは次の起動で台帳から再開するので、
        // 中身の無いサービスだけを OS に立て直させない
        return START_NOT_STICKY
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

    private fun ensureChannel() {
        // 通知チャンネルは Android 8.0 から。それより前はチャンネル無しで出る
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "転送", NotificationManager.IMPORTANCE_LOW),
        )
    }

    companion object {
        private const val CHANNEL = "transfers"
        private const val NOTIFICATION_ID = 42
        private const val ACTION_STOP = "app.r2gallery.transfer.STOP"

        /** 転送中か（サービスが前面で動いているか）。画面を閉じた時にエンジンを残すかの目安。 */
        @Volatile
        var running = false
            private set

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, TransferService::class.java))
        }

        fun stop(context: Context) {
            // サービスの onDestroy は後から届く。止めると決めた時点で転送中ではないとみなし、エンジンを畳む判断を遅らせない
            running = false
            // 動いていないサービスへ startService で止めに行くと、裏からの起動制限に掛かることがある
            context.stopService(Intent(context, TransferService::class.java))
        }
    }
}
