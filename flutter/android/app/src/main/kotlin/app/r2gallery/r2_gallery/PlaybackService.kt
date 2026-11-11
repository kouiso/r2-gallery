package app.r2gallery.r2_gallery

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionCommands
import com.google.common.util.concurrent.ListenableFuture

/** OS操作の状態proxyだけを所有する。ExoPlayerや音声decoderはここでは作らない。 */
@androidx.annotation.OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
    private var mediaSession: MediaSession? = null
    private var proxy: SessionPlayer? = null
    private val handler = Handler(Looper.getMainLooper())
    private var cpuLock: PowerManager.WakeLock? = null
    private var lockRenewedAt = 0L
    private val promotion = ForegroundPromotion()

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "動画の再生", NotificationManager.IMPORTANCE_LOW),
            )
        }
        // snapshotが先に消えた場合も、startForegroundServiceの契約を満たしてから止める。
        promotion.promote {
            val notification = NotificationCompat.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("R2 Gallery")
                .setContentText("再生を準備しています")
                .setOngoing(true).build()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(43, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(43, notification)
            }
        }
        setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this)
            .setChannelId(CHANNEL).setNotificationId(43).build())
        val state = PlaybackBridge.snapshot
        if (state == null) { clearSession(); stopSelf() } else applySnapshot(state)
    }

    fun applySnapshot(state: PlaybackSnapshot) {
        val player = proxy
        if (player == null || player.snapshot.session != state.session) {
            clearSession()
            val next = SessionPlayer(state)
            proxy = next
            mediaSession = MediaSession.Builder(this, next)
                .setSessionActivity(PendingIntent.getActivity(this, 0,
                    Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
                .setCallback(object : MediaSession.Callback {
                    override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
                        return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                            .setAvailableSessionCommands(SessionCommands.EMPTY)
                            .setAvailablePlayerCommands(COMMANDS).build()
                    }
                }).build().also { addSession(it) }
        } else {
            player.update(state)
        }
        updateCpu(state)
    }

    private fun updateCpu(state: PlaybackSnapshot) {
        if (state.playing && !state.ended) {
            val lock = cpuLock ?: getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "r2gallery:playback")
                .also { it.setReferenceCounted(false); cpuLock = it }
            val now = SystemClock.elapsedRealtime()
            if (!lock.isHeld || now - lockRenewedAt > 30_000) {
                // CPUだけを保ち、画面保持や電源ボタンの妨げには使わない。
                lock.acquire(60_000)
                lockRenewedAt = now
            }
        } else {
            releaseCpu()
        }
    }

    fun clearSession() {
        releaseCpu()
        mediaSession?.let { removeSession(it); it.release() }
        mediaSession = null
        proxy?.release()
        proxy = null
        promotion.stop {
            stopForeground(STOP_FOREGROUND_REMOVE)
            // 次の動画へのhandoffでは古い停止が新しい所有者を消さない。
            handler.postDelayed({ if (!PlaybackBridge.hasSession) stopSelf() }, 250)
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = mediaSession

    override fun onTaskRemoved(rootIntent: Intent?) {
        PlaybackBridge.command("close")
        clearSession()
        stopSelf()
    }

    override fun onDestroy() {
        val owned = proxy?.snapshot?.session
        clearSession()
        handler.removeCallbacksAndMessages(null)
        if (owned != null && PlaybackBridge.snapshot?.session == owned) PlaybackBridge.command("stop")
        PlaybackBridge.serviceDestroyed(this)
        if (instance === this) instance = null
        super.onDestroy()
        SharedEngine.releaseIfDetached(applicationContext)
    }

    private fun releaseCpu() {
        cpuLock?.let { if (it.isHeld) it.release() }
        cpuLock = null
    }

    private class SessionPlayer(var snapshot: PlaybackSnapshot) : SimpleBasePlayer(Looper.getMainLooper()) {
        fun update(state: PlaybackSnapshot) { snapshot = state; invalidateState() }
        override fun getState(): State {
            val state = snapshot
            val item = MediaItem.Builder().setMediaId(state.session)
                .setMediaMetadata(MediaMetadata.Builder().setTitle("R2 Gallery")
                    .setArtist("非公開の動画").build()).build()
            val data = MediaItemData.Builder(state.session).setMediaItem(item)
                .setDurationUs(state.duration * 1000).setIsSeekable(true).build()
            return State.Builder().setAvailableCommands(COMMANDS)
                .setPlaylist(listOf(data)).setCurrentMediaItemIndex(0)
                .setPlayWhenReady(state.playing, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
                .setPlaybackState(if (state.ended) Player.STATE_ENDED else if (state.buffering) Player.STATE_BUFFERING else Player.STATE_READY)
                .setPlaybackParameters(PlaybackParameters(state.speed))
                .setContentPositionMs(state.position.coerceIn(0, state.duration)).build()
        }
        override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> =
            PlaybackBridge.command(if (playWhenReady) "play" else "pause")
        override fun handleStop(): ListenableFuture<*> = PlaybackBridge.command("stop")
        override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> =
            PlaybackBridge.command("seek", positionMs.coerceAtLeast(0))
    }

    companion object {
        private const val CHANNEL = "r2-playback"
        @Volatile var instance: PlaybackService? = null
            private set
        private val COMMANDS = Player.Commands.Builder().addAll(
            Player.COMMAND_PLAY_PAUSE, Player.COMMAND_STOP,
            Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
            Player.COMMAND_SEEK_BACK, Player.COMMAND_SEEK_FORWARD,
            Player.COMMAND_GET_CURRENT_MEDIA_ITEM, Player.COMMAND_GET_TIMELINE,
            Player.COMMAND_GET_METADATA,
        ).build()
    }
}
