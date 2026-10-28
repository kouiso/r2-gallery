import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.Composable
import androidx.compose.ui.*
import androidx.compose.ui.unit.*
import app.r2gallery.model.*
import app.r2gallery.queue.*
import app.r2gallery.theme.AppTheme
import app.r2gallery.ui.*
import app.r2gallery.vm.*
import org.jetbrains.skia.EncodedImageFormat
import java.awt.Color as AwtColor
import java.awt.GradientPaint
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO

@OptIn(ExperimentalComposeUiApi::class)
fun renderPng(file: File, widthDp: Int, heightDp: Int, fontScale: Float = 1f, density: Float = 2.625f, content: @Composable () -> Unit) {
    val scene = ImageComposeScene(
        width = (widthDp * density).toInt(),
        height = (heightDp * density).toInt(),
        density = Density(density, fontScale),
        content = content,
    )
    var img = scene.render(0L)
    // 画像の非同期読み込みを待ちながら数回描き直す
    for (i in 1..12) { Thread.sleep(120); img = scene.render(i * 16_000_000L) }
    file.parentFile.mkdirs()
    file.writeBytes(img.encodeToData(EncodedImageFormat.PNG)!!.bytes)
    scene.close()
}

// 端末の写真の代わりに色のグラデーション画像を作る（実画像は載せない）
val thumbDir = File("/tmp/render-thumbs").also { it.mkdirs() }
fun thumb(i: Int): String {
    val f = File(thumbDir, "t$i.png")
    if (!f.exists()) {
        val img = BufferedImage(256, 256, BufferedImage.TYPE_INT_RGB)
        val g = img.createGraphics()
        val h = (i * 47 % 360) / 360f
        g.paint = GradientPaint(0f, 0f, AwtColor.getHSBColor(h, 0.45f, 0.75f), 256f, 256f, AwtColor.getHSBColor((h + 0.12f) % 1f, 0.6f, 0.35f))
        g.fillRect(0, 0, 256, 256); g.dispose()
        ImageIO.write(img, "png", f)
    }
    return "file://${f.absolutePath}"
}

val DAY = 86_400_000L
fun fakeItems(): List<MediaItem> {
    val now = System.currentTimeMillis()
    val days = listOf(0, 0, 0, 0, 0, 1, 1, 1, 5, 5, 5, 5, 5, 5, 11, 11, 11, 11)
    return days.mapIndexed { i, d ->
        MediaItem(
            key = "2026/10/IMG_${2000 + i}.${if (i % 7 == 2) "mp4" else "jpg"}",
            type = if (i % 7 == 2) "video" else "image",
            url = "", thumbUrl = thumb(i), createdAt = now - d * DAY - i * 3_600_000L, size = 3_000_000L + i,
        )
    }
}

val libs2 = listOf(Library("personal", "Personal"), Library("review", "Review"))

@Composable
fun Frame(content: @Composable ColumnScope.() -> Unit) {
    AppTheme { Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { Column(Modifier.fillMaxSize(), content = content) } }
}

fun noop() {}

@Composable
fun PhotosScene(selected: Int = 0, empty: Boolean = false, error: String? = null, readOnly: Boolean = false) {
    val items = if (empty || error != null) emptyList() else fakeItems().sortedByDescending { it.createdAt }
    val sel = items.take(selected).map { SelKey("personal", it.key) }.toSet()
    Frame {
        Box(Modifier.weight(1f)) {
            HomeContent(
                libs = libs2, lib = "personal",
                g = GalleryState(items = items, loaded = true, error = error),
                items = items, selection = sel, allSelected = false, libReadOnly = readOnly,
                onSelectLib = {}, onSort = {}, onLock = ::noop, onClearSelection = ::noop, onToggleAll = ::noop,
                onAdd = ::noop, onRefresh = ::noop, onOpenSettings = ::noop, onOpenItem = {}, onLoadMore = ::noop,
                onItemLongPress = {}, onToggleSelect = {}, onToggleDay = {},
            )
        }
        if (selected > 0) SelectionOpsBar(SelBarContent(listOf(addToAlbumAction {}, offlineAction {}, trashAction {})))
        else BottomTabs("home") {}
    }
}

@Composable
internal fun AlbumsScene(segment: AlbumsSegment = AlbumsSegment.ALBUMS) {
    val albums = listOf("練習記録" to 312, "お気に入り" to 48, "大会 2026" to 126, "動画" to 87)
        .mapIndexed { i, (t, c) -> Album("a$i", t, count = c, coverUrl = thumb(100 + i), readOnly = false) }
    val folders = listOf("2026/", "scan/", "movies/", "backup-old/").map { FolderNode(it, it.trimEnd('/')) }
    Frame {
        Box(Modifier.weight(1f)) {
            AlbumsTabContent(
                libs = libs2, lib = "personal", albums = albums, folders = folders, segment = segment, libReadOnly = false,
                onSelectLib = {}, onSegment = {}, onCreateAlbum = ::noop, onCreateFolder = ::noop,
                onOpenAlbum = {}, onAlbumMenu = {}, onOpenFolder = {}, onOpenTrash = ::noop,
            )
        }
        BottomTabs("albums") {}
    }
}


@Composable
internal fun ViewerScene(video: Boolean = false, saved: Boolean = false) {
    val actions = listOf(
        SelAction("情報", Icons.Default.Info) {},
        if (saved) SelAction("保存済み", Icons.Default.DownloadDone, accent = true) {} else offlineAction {},
        addToAlbumAction {},
        trashAction {},
    )
    AppTheme {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            Box(Modifier.fillMaxWidth().height(300.dp).align(Alignment.Center).background(Brush.linearGradient(listOf(Color(0xFF6B8F71), Color(0xFF27403A)))))
            ViewerTopBar("10月8日 木曜日 18:42", "12件目 · IMG_2041.${if (video) "mp4" else "jpg"}", {}, Modifier.align(Alignment.TopStart))
            Column(Modifier.align(Alignment.BottomStart)) {
                if (!video) ViewerMemo("夕方の練習。右手前の踏み込みが良くなってきた回。次回は常歩から速歩への移行をもう少し丁寧に。")
                ViewerActionBar(actions)
            }
        }
    }
}

@Composable
internal fun ViewerInfoScene(withReview: Boolean = true) {
    val review = if (withReview) ReviewMeta(
        verdict = "OK", round = 2, label = "フォーム確認", intentComment = "右手前の踏み込みを見たい",
        directorScore = 7.5, directorComment = "リズムは安定。収縮がやや浅い。", createdAt = 0,
        criteria = listOf(ReviewCriterion("rhythm", 1.0, panelScore = 7.0, directorScore = 8.0), ReviewCriterion("balance", 1.0, panelScore = 5.0, veto = true)),
    ) else null
    AppTheme {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            Box(Modifier.fillMaxWidth().height(220.dp).align(Alignment.TopCenter).background(Brush.linearGradient(listOf(Color(0xFF6B8F71), Color(0xFF27403A)))))
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f)))
            Surface(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().heightIn(max = 640.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                shape = MaterialTheme.shapes.extraLarge.copy(bottomStart = androidx.compose.foundation.shape.CornerSize(0.dp), bottomEnd = androidx.compose.foundation.shape.CornerSize(0.dp)),
            ) {
                ViewerInfoContent(
                    ViewerInfo(
                        name = "IMG_2041.jpg", isVideo = false, sizeText = "3.8 MB", addedAt = "10月8日 木曜日 18:42",
                        location = "Personal / 2026 / 10", note = "夕方の練習。右手前の踏み込みが良くなってきた回。", review = review,
                    ),
                    Modifier.padding(bottom = 24.dp),
                )
            }
        }
    }
}

fun task(id: String, name: String, kind: String, status: TransferStatus, size: Long, loaded: Long, error: String? = null, mime: String = "image/jpeg") =
    TransferTask(id = id, kind = kind, lib = "personal", prefix = "", name = name, size = size, loaded = loaded, status = status, error = error, mime = mime)

val mixedTasks = listOf(
    task("1", "IMG_2041.jpg", "up", TransferStatus.RUNNING, 4_200_000, 2_100_000),
    task("2", "練習動画_2026-10-08_長いファイル名のテスト.mp4", "up", TransferStatus.RUNNING, 180_000_000, 40_000_000, mime = "video/mp4"),
    task("3", "IMG_2043.jpg", "up", TransferStatus.QUEUED, 3_900_000, 0),
    task("4", "IMG_2039.jpg", "up", TransferStatus.ERROR, 3_100_000, 0, error = "サーバーに接続できませんでした"),
    task("5", "IMG_2038.jpg", "up", TransferStatus.DONE, 3_100_000, 3_100_000),
)

@Composable
internal fun TransfersStripScene(tasks: List<TransferTask>, online: Boolean = true) {
    val summary = summarizeTransfers(tasks, online)
    Frame {
        Box(Modifier.weight(1f)) { Text("（写真タブ）", Modifier.align(Alignment.Center)) }
        if (summary != null) TransfersStrip(summary, {})
        BottomTabs("home") {}
    }
}

@Composable
internal fun TransfersSheetScene(tasks: List<TransferTask>, online: Boolean = true) {
    AppTheme {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.4f))) {
            Surface(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().heightIn(max = 640.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                shape = MaterialTheme.shapes.extraLarge.copy(bottomStart = androidx.compose.foundation.shape.CornerSize(0.dp), bottomEnd = androidx.compose.foundation.shape.CornerSize(0.dp)),
            ) {
                TransfersSheetContent(
                    summarizeTransfers(tasks, online), tasks, online, {}, {}, {}, {}, {},
                    Modifier.padding(top = 16.dp, bottom = 24.dp),
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun TrashScene(items: List<TrashItem>, loading: Boolean = false, error: String? = null, canRestore: Boolean = true) {
    Frame {
        TopAppBar(title = { Text("ゴミ箱") })
        TrashContent(items, loading, error, restoring = items.take(1).map { it.trashKey }.toSet().takeIf { items.size > 2 } ?: emptySet(),
            nowMs = System.currentTimeMillis(), onRestore = {}, onRetry = {}, modifier = Modifier.weight(1f), canRestore = canRestore)
    }
}

fun fakeTrash(): List<TrashItem> {
    val now = System.currentTimeMillis()
    return listOf(
        TrashItem("t1", "2026/10/IMG_2041.jpg", now - 2 * 3_600_000L, 3_800_000),
        TrashItem("t2", "2026/10/練習動画_長いファイル名のテスト_2026-10-08.mp4", now - 1 * DAY, 180_000_000),
        TrashItem("t3", "scan/receipt.png", now - 9 * DAY, 640_000),
        TrashItem("t4", "2026/09/IMG_1800.jpg", now - 25 * DAY, 4_100_000),
    )
}

@Composable
internal fun SettingsScene(connected: Boolean = true, lockAvailable: Boolean = true, offline: Int = 12) {
    Frame {
        Box(Modifier.weight(1f)) {
            SettingsContent(
                SettingsUi(if (connected) "r2-gallery.example.workers.dev" else null, 2, lockAvailable, lockAvailable, 600_000, offline),
                {}, {}, {}, {},
            )
        }
        BottomTabs("settings") {}
    }
}

@Composable
internal fun ConnectScene(probeFailed: Boolean = false, failed: Boolean = false) {
    Frame { ConnectContent(probeFailed, "https://r2-gallery.example.workers.dev", "", false, failed, {}, {}, {}, {}) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun UploadScene(readOnly: Boolean = false, many: Boolean = true) {
    val items = if (many) (1..8).map { UploadItem("IMG_20${40 + it}.jpg", 3_800_000L + it) } + UploadItem("練習動画_長いファイル名のテスト_2026-10-08.mp4", 0)
    else listOf(UploadItem("IMG_2041.jpg", 3_800_000))
    AppTheme {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.4f))) {
            Surface(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth(),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                shape = MaterialTheme.shapes.extraLarge.copy(bottomStart = androidx.compose.foundation.shape.CornerSize(0.dp), bottomEnd = androidx.compose.foundation.shape.CornerSize(0.dp)),
            ) {
                UploadConfirmContent(summarizeUpload(items), "Personal", readOnly, onConfirm = {}, onCancel = {}, modifier = Modifier.padding(top = 24.dp))
            }
        }
    }
}

@Composable
internal fun ImportScene(sheet: Boolean = false, block: SaveBlock? = null) {
    val rows = listOf(
        DetectedRowData("1", "video_1080p.mp4", "動画・cdn.example.com", Icons.Default.Info),
        DetectedRowData("2", "とても長いファイル名のテスト_練習動画_2026-10-08_final_version.mp4", "HLS動画・media.example.net", Icons.Default.Info),
        DetectedRowData("3", "cover.jpg", "画像・img.example.com", Icons.Default.Info),
    )
    Frame {
        if (!sheet) {
            Box(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text("（ページ表示）", Modifier.align(Alignment.Center))
            }
            // ページに重ねず、下に場所を取る（実画面と同じ並び）
            DetectionBar(3, {}, Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
            BottomTabs("import") {}
        } else {
            Box(Modifier.weight(1f).background(Color.Black.copy(alpha = 0.4f))) {
                Surface(Modifier.align(Alignment.BottomCenter).fillMaxWidth(), color = MaterialTheme.colorScheme.surfaceContainerLow,
                    shape = MaterialTheme.shapes.extraLarge.copy(bottomStart = androidx.compose.foundation.shape.CornerSize(0.dp), bottomEnd = androidx.compose.foundation.shape.CornerSize(0.dp))) {
                    DetectedSheetContent(rows, block, {}, {}, Modifier.padding(top = 16.dp))
                }
            }
        }
    }
}

data class Scene(val name: String, val content: @Composable () -> Unit)

val scenes = listOf(
    Scene("01-photos") { PhotosScene() },
    Scene("02-photos-selected") { PhotosScene(selected = 3) },
    Scene("03-albums") { AlbumsScene() },
    Scene("04-folders") { AlbumsScene(AlbumsSegment.FOLDERS) },
    Scene("05-photos-empty") { PhotosScene(empty = true) },
    Scene("06-photos-error") { PhotosScene(error = "HTTP 503 Service Unavailable") },
    Scene("07-viewer") { ViewerScene() },
    Scene("08-viewer-video-saved") { ViewerScene(video = true, saved = true) },
    Scene("09-viewer-info") { ViewerInfoScene() },
    Scene("10-transfers-strip") { TransfersStripScene(mixedTasks) },
    Scene("11-transfers-strip-failed") { TransfersStripScene(mixedTasks.filter { it.status == TransferStatus.ERROR }) },
    Scene("12-transfers-strip-offline") { TransfersStripScene(listOf(task("3", "IMG_2043.jpg", "up", TransferStatus.QUEUED, 3_900_000, 0)), online = false) },
    Scene("13-transfers-sheet") { TransfersSheetScene(mixedTasks) },
    Scene("14-trash") { TrashScene(fakeTrash()) },
    Scene("15-trash-empty") { TrashScene(emptyList()) },
    Scene("16-trash-error") { TrashScene(emptyList(), error = "HTTP 503 Service Unavailable") },
    Scene("17-settings") { SettingsScene() },
    Scene("18-settings-nolock-disconnected") { SettingsScene(connected = false, lockAvailable = false, offline = 0) },
    Scene("19-lock") { Frame { LockContent(false, {}) } },
    Scene("20-lock-failed") { Frame { LockContent(true, {}) } },
    Scene("21-no-credential") { Frame { NoCredentialContent({}) } },
    Scene("22-connect") { ConnectScene() },
    Scene("23-connect-unreachable") { ConnectScene(probeFailed = true, failed = true) },
    Scene("24-upload-confirm") { UploadScene() },
    Scene("25-upload-confirm-readonly") { UploadScene(readOnly = true, many = false) },
    Scene("26-import-bar") { ImportScene() },
    Scene("27-import-sheet") { ImportScene(sheet = true) },
    Scene("29-trash-readonly") { TrashScene(fakeTrash(), canRestore = false) },
    Scene("30-trash-refresh-failed") { TrashScene(fakeTrash(), error = "HTTP 503") },
    Scene("31-import-sheet-readonly") { ImportScene(sheet = true, block = SaveBlock.READ_ONLY) },
    Scene("28-import-sheet-noconn") { ImportScene(sheet = true, block = SaveBlock.NOT_CONNECTED) },
)

// 幅 x 高さ(dp) と文字倍率。320dp×文字1.3 が一番厳しい組み合わせ
val sizes = listOf(Triple(320, 640, 1.3f), Triple(390, 844, 1.0f), Triple(390, 844, 1.3f), Triple(412, 915, 1.0f))

fun main(args: Array<String>) {
    val out = File(args.firstOrNull() ?: "out")
    val only = args.getOrNull(1)
    for (s in scenes) {
        if (only != null && !s.name.startsWith(only)) continue
        for ((w, h, f) in sizes) {
            renderPng(File(out, "${s.name}_${w}dp_x${f}.png"), w, h, f, content = s.content)
        }
    }
    println("done")
}
