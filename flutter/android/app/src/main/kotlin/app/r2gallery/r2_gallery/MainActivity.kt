package app.r2gallery.r2_gallery

import android.content.res.Configuration
import android.media.AudioManager
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.view.WindowManager
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterFragmentActivity
import kotlin.math.roundToInt
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// local_auth の BiometricPrompt は FragmentActivity にしか載せられない
class MainActivity : FlutterFragmentActivity() {
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
        // 古いDartコードから呼ばれても、アプリ専用の保存を共有領域へ書き出さない。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.r2gallery/export")
            .setMethodCallHandler { _, result ->
                result.error("private_storage_only", "外部への書き出しは利用できません", null)
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
        PlaybackBridge.pipChanged(inPip)
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
}
