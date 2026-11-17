package app.r2gallery.r2_gallery

import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import android.os.Handler
import android.os.Looper

private fun Handler_main() = Handler(Looper.getMainLooper())

// file_picker は選んだ全件を cacheDir/file_picker へ写し、写せない1件は黙って返さない。
// 5000件級では写しだけで端末の空きが尽きるので、写真・動画の選択はこの口に替える。
// こちらは content:// の URI と表示名・大きさ・種類だけを返し、写しを作らない。
// 権利は画面が生きている間だけ有効なので、退避（copyToFile）は積んだ直後に行う。
class UploadPicker(private val activity: MainActivity) {
    private var pending: MethodChannel.Result? = null

    private val launcher =
        activity.registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            val out = pending ?: return@registerForActivityResult
            pending = null
            if (res.resultCode != android.app.Activity.RESULT_OK || res.data == null) {
                out.success(emptyList<Any>())
                return@registerForActivityResult
            }
            val uris = mutableListOf<Uri>()
            res.data?.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            }
            res.data?.data?.let { uris.add(it) }
            // 持続権利を取れる環境では取っておく（再起動後も退避の写しが効く）
            for (u in uris) {
                try {
                    activity.contentResolver.takePersistableUriPermission(
                        u, Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                } catch (_: Exception) {}
            }
            val items = uris.map { describe(it) }
            Handler_main().post { out.success(items) }
        }

    fun register(exec: DartExecutor) {
        MethodChannel(exec.binaryMessenger, "app.r2gallery/upload_picker")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pick" -> pick(call, result)
                    "copyToFile" -> copyToFile(call, result)
                    "freeBytes" -> freeBytes(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        // 2つの選択を重ねない。開いている間に呼ばれたら空で返す
        if (pending != null) {
            result.success(emptyList<Any>())
            return
        }
        // GET_CONTENT は機種によって写真ピッカーになり、返る URI が表示名を持たないことがある。
        // OPEN_DOCUMENT は DocumentsUI を開き、表示名・大きさと持続する読み取り権利が取れる
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        pending = result
        try {
            launcher.launch(intent)
        } catch (e: Exception) {
            pending = null
            result.error("failed", "ピッカーを開けませんでした", e.toString())
        }
    }

    // content:// の URI から退避先へ直に写す。途中で権利が切れた・消された時は例外を返す
    private fun copyToFile(call: MethodCall, result: MethodChannel.Result) {
        val uriStr = call.argument<String>("uri")
        val destPath = call.argument<String>("dest")
        if (uriStr == null || destPath == null) {
            result.error("bad_args", "uri/dest is required", null)
            return
        }
        Thread {
            val err = try {
                val dest = File(destPath)
                dest.parentFile?.mkdirs()
                activity.contentResolver.openInputStream(Uri.parse(uriStr)).use { input ->
                    requireNotNull(input) { "input stream unavailable" }
                    FileOutputStream(dest).use { output -> input.copyTo(output, 1 shl 20) }
                }
                null
            } catch (e: Exception) {
                e
            }
            Handler_main().post {
                if (err == null) {
                    result.success(null)
                } else {
                    // 半端に書けた分は呼び出し側の失敗行が残る。欠けた file を掃除しておく
                    try { File(destPath).delete() } catch (_: Exception) {}
                    result.error("copy_failed", "ファイルを端末に退避できませんでした", err.toString())
                }
            }
        }.start()
    }

    private fun freeBytes(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: activity.filesDir.absolutePath
        result.success(File(path).usableSpace)
    }

    private fun mediaStoreInfo(uri: Uri): Pair<String?, Long> {
        val id = uri.lastPathSegment?.toLongOrNull() ?: return Pair(null, -1)
        var c: Cursor? = null
        try {
            c = activity.contentResolver.query(
                android.content.ContentUris.withAppendedId(
                    android.provider.MediaStore.Files.getContentUri("external"), id,
                ),
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null,
            )
            if (c != null && c.moveToFirst()) {
                val n = if (c.isNull(0)) null else c.getString(0)
                val s = if (c.isNull(1)) -1L else c.getLong(1)
                return Pair(n, s)
            }
        } catch (_: Exception) {
        } finally {
            c?.close()
        }
        return Pair(null, -1)
    }

    private fun describe(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var size: Long = -1
        var mime: String? = activity.contentResolver.getType(uri)
        var c: Cursor? = null
        try {
            c = activity.contentResolver.query(uri, null, null, null, null)
            if (c != null && c.moveToFirst()) {
                val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (ni >= 0) name = c.getString(ni)
                val si = c.getColumnIndex(OpenableColumns.SIZE)
                if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
            }
        } catch (_: Exception) {
        } finally {
            c?.close()
        }
        // picker URI は DISPLAY_NAME/SIZE を持たず末尾が media 番号になる機種がある。
        // その時は Files 側へ問い直して実ファイル名と大きさを拾う（番号だけでは名も量も分からない）
        if (name == null || size < 0) {
            val info = mediaStoreInfo(uri)
            if (name == null) name = info.first
            if (size < 0) size = info.second
        }
        if (name == null) name = uri.lastPathSegment ?: "media"
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "size" to size,
            "mime" to (mime ?: "application/octet-stream"),
        )
    }
}
