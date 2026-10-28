package app.r2gallery.r2_gallery

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import java.lang.ref.WeakReference

/**
 * 画面（MainActivity）より長生きする Flutter エンジン。
 * 転送中は最近使ったアプリの一覧から消されても、フォアグラウンドサービスがプロセスを生かし、
 * このエンジンの上で Dart の転送が最後まで走る。画面が無い間に転送が終わったら、ここで畳む。
 *
 * 画面ごとに新しく作るエンジン（FlutterFragment の既定）は、画面と一緒に必ず壊される。
 * だからエンジンはキャッシュに置き、画面にはキャッシュの id で渡す（キャッシュのエンジンは画面が壊さない）。
 */
object SharedEngine {
    const val ENGINE_ID = "r2g-shared"

    // 閉じた画面をここで握り続けないよう弱参照にする
    private var host: WeakReference<Activity>? = null

    /** Dart 側がロック中に窓の保護を頼んだか。つなぎ直した画面に付け直すために覚えておく。 */
    @Volatile
    var secureWindow = false

    /** 画面を作る前に呼ぶ。エンジンが無ければ作って Dart を走らせ、あればそのまま使う。 */
    fun attach(activity: Activity) {
        host = WeakReference(activity)
        val cache = FlutterEngineCache.getInstance()
        if (cache.get(ENGINE_ID) != null) return
        // プラグインはエンジンの生成時に自動で登録される。キャッシュのエンジンは画面側が Dart を起動しないので、ここで起動する
        val engine = FlutterEngine(activity.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
    }

    /**
     * 画面が閉じた。転送が動いていなければこれまで通りエンジンも畳み、動いていれば残す。
     * 新しい画面が先につながっていた時（古い画面の後始末が遅れて届いた時）は何もしない。
     */
    fun detach(activity: Activity) {
        if (host?.get() !== activity) return
        host = null
        if (!TransferService.running) release(activity.applicationContext)
    }

    private fun release(context: Context) {
        host = null
        TransferBridge.release(context)
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.destroy()
        cache.remove(ENGINE_ID)
        secureWindow = false
    }

    /**
     * 画面が無いまま転送が終わった時。少し待ってから畳む。
     * Dart 側は台帳を書き終えてから止めに来るが、同じ時に終わった別の転送の後始末（台帳の書き込み）を途中で切らないため。
     * 待つ間に画面が戻るか転送が始まれば畳まない。
     */
    fun releaseIfDetached(context: Context) {
        Handler(Looper.getMainLooper()).postDelayed({
            val alive = FlutterEngineCache.getInstance().get(ENGINE_ID) != null
            if (host?.get() == null && alive && !TransferService.running) release(context)
        }, RELEASE_DELAY_MS)
    }

    private const val RELEASE_DELAY_MS = 3_000L
}
