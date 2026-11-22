package app.r2gallery.r2_gallery

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ContentValues
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.AudioManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import android.view.WindowManager
import android.webkit.CookieManager
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterFragmentActivity
import java.io.File
import kotlin.math.roundToInt
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth の BiometricPrompt は FragmentActivity にしか載せられない
class MainActivity : FlutterFragmentActivity() {
    // Android 9 以下で「端末に保存」の書き込み許可を尋ねた結果の受け口
    private var pendingWritePermission: ((Boolean) -> Unit)? = null
    private val writePermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            pendingWritePermission?.invoke(granted)
            pendingWritePermission = null
        }
    private var playerBrightnessBefore: Float? = null
    private var playerForeground = false
    // 転送中に最近使ったアプリの一覧から消されても Dart 側の取り込み・アップロードを続けるため、
    // エンジンは画面より長く生かす。次に開いた画面は同じエンジンにつなぎ直す
    // （新しいエンジンで2つ目の Dart を起こすと、台帳から同じ転送を二重に走らせてしまう）
    override fun onCreate(savedInstanceState: Bundle?) {
        // 画面（FlutterFragment）を作る前にエンジンを用意する。作る時にキャッシュの id で引くため
        SharedEngine.attach(this)
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineId(): String = SharedEngine.ENGINE_ID

    // キャッシュのエンジンは画面と一緒に壊さない。畳むのは SharedEngine が決める
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // つなぎ直した画面は新しい窓なので、ロック中に付けていた「スクショ・一覧に中身を残さない」を付け直す
        if (SharedEngine.secureWindow) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        // 「端末に保存」。書き込み許可のダイアログと裏スレッドでのコピーをこの口で行う
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.r2gallery/export")
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                val name = call.argument<String>("name")
                val mime = call.argument<String>("mime")
                if (call.method != "save" || path == null || name == null || mime == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                withWritePermission { granted ->
                    if (!granted) {
                        result.error("denied", "ストレージへのアクセスが許可されていません", null)
                        return@withWritePermission
                    }
                    // 大きい動画のコピーで画面を固めないよう、書き込みは裏のスレッドで行う
                    Thread {
                        val err = try {
                            saveToMediaStore(File(path), name, mime)
                            null
                        } catch (e: Exception) {
                            e
                        }
                        Handler(Looper.getMainLooper()).post {
                            if (err == null) {
                                result.success(null)
                            } else {
                                result.error("failed", "端末への保存に失敗しました", err.toString())
                            }
                        }
                    }.start()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.r2gallery/player")
            .setMethodCallHandler { call, result ->
                val audio = getSystemService(AudioManager::class.java)
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                when (call.method) {
                    "setKeepScreenOn" -> {
                        val keep = call.arguments == true && playerForeground
                        if (keep) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(keep)
                    }
                    "getVolume" -> result.success(
                        if (max > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max else null,
                    )
                    "setVolume" -> {
                        val v = (call.arguments as? Double)
                        if (v == null || max <= 0) {
                            result.success(null)
                        } else {
                            val idx = (v.coerceIn(0.0, 1.0) * max).roundToInt()
                            try {
                                audio.setStreamVolume(AudioManager.STREAM_MUSIC, idx, 0)
                                result.success(idx.toDouble() / max)
                            } catch (e: SecurityException) {
                                // おやすみモード中などは端末が音量の変更を拒む
                                result.error("denied", e.message, null)
                            }
                        }
                    }
                    // この窓で上書き中ならその値、端末任せ（-1）なら端末がいま出している明るさを返す。
                    // 未設定を固定値に見立てると、ドラッグの最初の一動きで急に明るさが飛ぶ（#198）。
                    // 実際の値を読めない時（端末が自動調整中）は null を返し、実値のように見せない
                    "getBrightness" -> {
                        val b = window.attributes.screenBrightness
                        result.success(if (b >= 0f) b.toDouble() else deviceBrightness())
                    }
                    // 端末が明るさを自動調整している間か。読めない理由を利用者へ伝えるために使う
                    "isAutoBrightness" -> result.success(isAutoBrightness())
                    "setBrightness" -> {
                        val v = (call.arguments as? Double)?.coerceIn(0.02, 1.0)
                        if (v == null) {
                            result.success(null)
                        } else {
                            val lp = window.attributes
                            if (playerBrightnessBefore == null) playerBrightnessBefore = lp.screenBrightness
                            lp.screenBrightness = v.toFloat()
                            window.attributes = lp
                            result.success(v)
                        }
                    }
                    "resetBrightness" -> {
                        val lp = window.attributes
                        lp.screenBrightness = playerBrightnessBefore
                            ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        window.attributes = lp
                        playerBrightnessBefore = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.r2gallery/lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 再ロック猶予はスリープ中も進み、端末の時計を戻しても縮まん時計で測る
                    "elapsedRealtime" -> result.success(SystemClock.elapsedRealtime())
                    // ロックを使う間は、最近使ったアプリの一覧やスクショに中身を残さない
                    "setSecure" -> {
                        SharedEngine.secureWindow = call.arguments == true
                        if (call.arguments == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // 前回までの終了理由を Dart 側の ExitLog へ渡す口（#1 作業1）。
        // クラッシュの原因を adb の logcat・dumpsys activity exit-info から追えるようにする
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.r2gallery/diag")
            .setMethodCallHandler { call, result ->
                if (call.method != "exitReasons") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                // Android 10 以下は OS が終了理由を持たない
                if (Build.VERSION.SDK_INT < 30) {
                    result.success(emptyList<Map<String, Any?>>())
                    return@setMethodCallHandler
                }
                try {
                    val am = getSystemService(ActivityManager::class.java)
                    val exits = am?.getHistoricalProcessExitReasons(packageName, 0, 5)
                        ?: emptyList()
                    result.success(
                        exits.map { info ->
                            mapOf<String, Any?>(
                                "reason" to info.reason,
                                "reasonName" to exitReasonName(info.reason),
                                "description" to info.description,
                                "timestamp" to info.timestamp,
                                "pss" to info.pss,
                                "rss" to info.rss,
                                "importance" to info.importance,
                                "status" to info.status,
                                "trace" to exitTrace(info),
                            )
                        },
                    )
                } catch (e: Exception) {
                    result.error("diag", e.message, null)
                }
            }
        // 取り込みブラウザが拾ったメディアを、ページと同じ Cookie で取り直すための口。
        // webview_flutter は Cookie の読み出しを公開しておらず、HttpOnly の Cookie は JS からも読めない。
        // Dart 側からしか呼べない口で、閲覧中のページ（JS）からは届かない
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.r2gallery/cookies")
            .setMethodCallHandler { call, result ->
                val url = call.arguments as? String
                if (call.method == "get" && url != null &&
                    (url.startsWith("https://") || url.startsWith("http://"))
                ) {
                    result.success(CookieManager.getInstance().getCookie(url))
                } else {
                    result.notImplemented()
                }
            }
        // アップロード・オフライン保存を裏でも続けるためのサービスと、回線の回復の知らせ
        TransferBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        // 写真・動画の選択は file_picker の写しをやめ、URI だけを返すこの口へ
        UploadPicker(this).register(flutterEngine.dartExecutor)
    }

    override fun onResume() {
        super.onResume()
        playerForeground = true
    }

    override fun onPause() {
        playerForeground = false
        // 電源ボタン・他アプリへの移動を妨げず、Dart の通知が遅れても窓の保持を外す。
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onPause()
    }

    override fun onPictureInPictureModeChanged(inPip: Boolean, configuration: Configuration) {
        super.onPictureInPictureModeChanged(inPip, configuration)
        // 閉じた時点で画面が STARTED 以上なら「元に戻す」、そうでなければ ×。時間差は使わない
        val restoring = PipPolicy.restoring(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        PlaybackBridge.pipChanged(inPip, if (inPip) null else restoring)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        PlaybackBridge.userLeaveHint(this)
    }

    override fun onStop() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onStop()
    }

    override fun onDestroy() {
        super.onDestroy()
        // 回転などで作り直すだけの時はエンジンをそのまま次の画面へ渡す
        if (!isChangingConfigurations) SharedEngine.detach(this)
    }

    // ApplicationExitInfo は理由を定数でしか持たないので、読む人のために定数名に写す
    private fun exitReasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        else -> "REASON_$reason"
    }

    // ANR とネイティブの異常終了の時だけスタックの先頭 16KB を残す。
    // 低メモリの終了にはスタックが無く、読めない時は trace 無しで返す
    private fun exitTrace(info: ApplicationExitInfo): String? {
        if (info.reason != ApplicationExitInfo.REASON_ANR &&
            info.reason != ApplicationExitInfo.REASON_CRASH_NATIVE
        ) {
            return null
        }
        return try {
            info.traceInputStream?.use { s ->
                val buf = ByteArray(16 * 1024)
                val n = s.read(buf)
                if (n > 0) String(buf, 0, n) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    // 端末がいま画面に出している明るさ（0.0〜1.0）。実際の値を読めなければ null。
    // 設定値（SCREEN_BRIGHTNESS）は手動で決めた明るさで、自動調整中に画面が出している値とは別物。
    // 自動調整中の実際の値を読む公開 API は無いので、その間は読めないものとして返す（#198）
    private fun deviceBrightness(): Double? {
        if (isAutoBrightness()) return null
        return try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255.0
        } catch (e: Settings.SettingNotFoundException) {
            null
        }
    }

    private fun isAutoBrightness(): Boolean = try {
        Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE) ==
            Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC
    } catch (e: Settings.SettingNotFoundException) {
        false
    }

    private fun withWritePermission(then: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT >= 29 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            then(true)
            return
        }
        // 尋ねている最中に重ねて呼ばれたら、先の問い合わせの答えを待たずに断る（応答を取りこぼさない）
        if (pendingWritePermission != null) {
            then(false)
            return
        }
        pendingWritePermission = then
        writePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
    }

    // KMP 版 MediaExporter と同じ置き場（Pictures/R2Gallery・Movies/R2Gallery）
    private fun saveToMediaStore(src: File, displayName: String, mime: String) {
        val isVideo = mime.startsWith("video/")
        val resolver = contentResolver
        val collection = if (isVideo) {
            if (Build.VERSION.SDK_INT >= 29) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
        } else {
            if (Build.VERSION.SDK_INT >= 29) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
        }
        val dirName = if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$dirName/R2Gallery")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            } else {
                // 従来の置き場を明示する。insert だけだとギャラリーの走査対象から外れることがある
                val dir = File(Environment.getExternalStoragePublicDirectory(dirName), "R2Gallery")
                dir.mkdirs()
                put(MediaStore.MediaColumns.DATA, File(dir, displayName).absolutePath)
            }
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore insert returned null")
        try {
            val out = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("MediaStore output stream unavailable")
            out.use { o -> src.inputStream().use { it.copyTo(o, 1 shl 20) } }
            if (Build.VERSION.SDK_INT >= 29) {
                val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                resolver.update(uri, done, null, null)
            } else {
                // IS_PENDING が無い版は走査を明示して呼ぶ
                MediaScannerConnection.scanFile(
                    this,
                    arrayOf(values.getAsString(MediaStore.MediaColumns.DATA)),
                    arrayOf(mime),
                    null,
                )
            }
        } catch (e: Exception) {
            // 書き込み途中で失敗した時に、中身の無い行をギャラリーへ残さない
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
