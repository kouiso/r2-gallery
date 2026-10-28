import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../store/kv.dart';
import '../transfer/transfer_queue.dart' show LedgerStore;
import 'detected.dart';
import 'hls.dart';
import 'media_name.dart';
import 'url_policy.dart';
import 'web_fetcher.dart';
import 'web_history.dart';

enum WebTaskStatus { queued, fetching, uploading, done, error, cancelled, paused }

/// 取り込み1件。ネットから端末へ取る→端末から R2 へ上げる、の2段を1つの行で見せる。
class WebTransferTask {
  WebTransferTask({
    required this.id,
    required this.lib,
    required this.url,
    required this.headers,
    required this.hls,
    required this.name,
    required this.mime,
  });

  final String id;
  final String lib;
  final String url;
  final Map<String, String> headers;
  final bool hls;
  final String name;
  final String mime;

  WebTaskStatus status = WebTaskStatus.queued;
  int loaded = 0;
  int size = 0;
  int hlsSeg = 0;
  int hlsTotal = 0;

  /// 端末に落とし終えたファイルに実際に追記したバイト数。再試行時に
  /// ファイルの実サイズと食い違えば、セグメント境界を推測せず最初から取り直す。
  int hlsBytes = 0;
  String? hlsVariant;
  String? error;

  /// R2 に確定したキー。
  String? key;

  /// 今送っている（または最後に送りかけた）キーと、その何番目の名前か。
  /// 送り終えた直後に落とされても、次の起動でこのキーを確かめて二重に上げない。
  String? pendingKey;
  int keyAttempt = 0;
  File? staged;
  CancelToken? cancel;

  bool get active =>
      status == WebTaskStatus.queued ||
      status == WebTaskStatus.fetching ||
      status == WebTaskStatus.uploading;

  bool get finished => !active && status != WebTaskStatus.paused;

  /// 台帳に残す中身。アプリが消えても、次の起動で続きから取る／送るのに要るものだけ。
  Map<String, dynamic> toLedger() => {
        'id': id,
        'lib': lib,
        'url': url,
        'headers': headers,
        'hls': hls,
        'name': name,
        'mime': mime,
        'status': status.name,
        if (error != null) 'error': error,
        'size': size,
        'hlsSeg': hlsSeg,
        'hlsBytes': hlsBytes,
        'hlsTotal': hlsTotal,
        if (hlsVariant != null) 'hlsVariant': hlsVariant,
        if (pendingKey != null) 'pendingKey': pendingKey,
        'keyAttempt': keyAttempt,
        // 端末に取り終えたか。取り終えていれば次は送るだけで済む
        'fetched': staged != null,
      };

  /// 一時停止を頼まれた。止まった時に取り消しと区別し、落とした分を残すため。
  bool pauseRequested = false;

  /// 一覧に出す進捗。HLS は総バイト数が分からんのでセグメント数で数える。
  int get percent {
    if (hls && status == WebTaskStatus.fetching && hlsTotal > 0) {
      return (hlsSeg * 100 ~/ hlsTotal).clamp(0, 100);
    }
    if (size <= 0) return 0;
    return (loaded * 100 ~/ size).clamp(0, 100);
  }
}

/// ネット取り込みの台帳の置き場（アップロードの台帳とは別のキー）。
class KvWebLedgerStore implements LedgerStore {
  const KvWebLedgerStore();
  static const key = 'r2g.webQueue';
  @override
  Future<String?> read() => Kv.get(key);
  @override
  Future<void> write(String json) => Kv.set(key, json);
}

/// 検出したメディアを R2 に置く時の名前と MIME。HLS は取った中身が ts なのでそう名付ける。
({String name, String mime}) webUploadTarget(DetectedItem it) {
  final isHls = it.kind == DetectedKind.hls;
  final mime = isHls ? 'video/mp2t' : mimeForName(it.displayName);
  final base = isHls
      ? '${it.displayName.replaceFirst(RegExp(r'\.m3u8$', caseSensitive: false), '')}.ts'
      : it.displayName;
  return (name: normalizeUploadName(base, mime), mime: mime);
}

/// ギャラリーの一覧に出る形式か。音声などは保存できても一覧に出ず、見えないゴミになる。
bool isWebSavable(DetectedItem it) => hasListedExtension(webUploadTarget(it).name);

typedef ThumbMaker = Future<Uint8List?> Function(File file, String mime);

/// ブラウザで見つけたメディアを「端末に取る→R2 に上げる」キュー。
/// KMP 版 TransferQueue の web/hls 経路に対応する。大きい動画でメモリが膨らまんよう、
/// 取得は端末の一時ファイルへ追記し、アップロードも1パートずつ読んで流す。
class WebTransferQueue extends ChangeNotifier {
  WebTransferQueue({
    required this.api,
    WebFetcher? fetcher,
    Directory? stageDir,
    this.makeThumb,
    WebHistoryStore? history,
    this.parallel = 2,
    this.maxNetRetries = 3,
    this.retryDelay = const Duration(seconds: 2),
    this.ledger,
    Future<Directory> Function()? persistentStageDir,
  })  : fetcher = fetcher ?? WebFetcher(),
        history = history ?? WebHistoryStore(),
        _persistentDirFn = persistentStageDir,
        _dir = stageDir;

  final ApiClient api;
  final WebFetcher fetcher;
  final WebHistoryStore history;
  final ThumbMaker? makeThumb;
  final int parallel;
  final int maxNetRetries;
  final Duration retryDelay;

  /// 同名キーが既にある時に「name (2)」…「name (9)」まで順に試す回数（KMP 版と同じ）。
  static const maxKeyAttempts = 9;

  /// アプリが消えても残る一時ファイルの置き場。OS の一時領域は再起動で消されることがあるため。
  static Future<Directory> defaultStageDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/web-stage');

  /// 取り込みの台帳。無ければ記録しない（テストや Web 版）。
  final LedgerStore? ledger;
  final Future<Directory> Function()? _persistentDirFn;
  Future<void> _persistChain = Future.value();
  final Set<WebTransferTask> _completing = {};
  int _lastPersistMs = 0;
  Future<void>? _restoring;
  bool _restoreDone = false;

  /// 台帳を読めなかった（保存先の一時的な失敗など）。読めていない台帳を空で上書きすると、
  /// 前回の取り込みが次の起動でも戻せなくなるので、この起動では台帳に書かない。
  bool _ledgerUnreadable = false;

  Directory? _dir;
  bool _ownsDir = false;
  final List<WebTransferTask> _tasks = [];
  final Set<String> _running = {};
  final List<Completer<void>> _idleWaiters = [];
  int _seq = 0;
  final String _session =
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  int _lastNotifyMs = 0;
  bool _disposed = false;

  List<WebTransferTask> get tasks => List.unmodifiable(_tasks);
  int get activeCount => _tasks.where((t) => t.active).length;

  /// 保存を積む。同じ保存先で処理中の同じ URL は積み直さない。積んだ行を返す。
  List<WebTransferTask> enqueue(String lib, List<DetectedItem> items) {
    final inFlight = {
      for (final t in _tasks)
        if (t.lib == lib && t.active) t.url,
    };
    final added = <WebTransferTask>[];
    for (final it in items) {
      if (!inFlight.add(it.url)) continue;
      final target = webUploadTarget(it);
      final t = WebTransferTask(
        // 前回の起動の台帳から戻した行と重ならないよう、起動ごとに変わる値を混ぜる（一時ファイル名にも使う）
        id: 'w${_session}_${++_seq}',
        lib: lib,
        url: it.url,
        headers: it.headers,
        hls: it.kind == DetectedKind.hls,
        name: target.name,
        mime: target.mime,
      );
      if (!isWebUrl(t.url)) {
        // 検出一覧はページ（信用できん側）が送ってくる。端末内などへ向く URL は取りに行かない
        t.status = WebTaskStatus.error;
        t.error = 'http/https 以外の URL は保存できません';
      } else if (!hasListedExtension(t.name)) {
        // 一覧に出ない形式は、上げても見えないので取りに行かず理由を出す
        t.status = WebTaskStatus.error;
        t.error = 'ギャラリーに表示できない形式です（動画・画像のみ保存できます）';
      }
      _tasks.add(t);
      added.add(t);
    }
    _changed();
    unawaited(_persist());
    _pump();
    return added;
  }

  /// 前回の起動の台帳を読み戻し、途中だった取り込みを続きから再開する。何度呼んでも1回だけ。
  /// 一時停止していた行は止めたまま、失敗していた行は理由とやり直しボタン付きで戻す。
  Future<void> restore() => _restoring ??= _restore();

  Future<void> _restore() async {
    final ledger = this.ledger;
    if (ledger == null) {
      _restoreDone = true;
      return;
    }
    final restored = <WebTransferTask>[];
    var readOk = false;
    try {
      final dir = await _ensureDir();
      final raw = await ledger.read();
      readOk = true;
      final decoded = raw == null || raw.isEmpty ? null : jsonDecode(raw);
      if (decoded is List) {
        // 読み戻す前に積まれた行と id が重なる行は、同じ取り込みなので二重に戻さない
        final known = {for (final t in _tasks) t.id};
        for (final e in decoded) {
          final t = await _fromLedger(e, dir);
          if (t != null && known.add(t.id)) restored.add(t);
        }
      }
    } on FormatException catch (e) {
      // 中身が壊れた台帳は直しようがない。空として扱い、次の書き込みで置き換える
      readOk = true;
      debugPrint('web ledger unreadable: $e');
    } on Exception catch (e) {
      debugPrint('web ledger not restored: $e');
    }
    _ledgerUnreadable = !readOk;
    _restoreDone = true;
    if (_disposed) return;
    _tasks.insertAll(0, restored);
    // 読めなかった時は、台帳が指す一時ファイルを消さない
    if (readOk) await _sweepUnreferenced();
    _changed();
    // ここで書き終わりを待たない。読み終えるのを待っている先の書き込みが、この後ろに並んでいるため
    unawaited(_persist());
    _pump();
  }

  Future<WebTransferTask?> _fromLedger(Object? e, Directory dir) async {
    if (e is! Map) return null;
    final id = e['id'], lib = e['lib'], url = e['url'], name = e['name'];
    final mime = e['mime'], hls = e['hls'], headers = e['headers'];
    if (id is! String || lib is! String || url is! String || name is! String ||
        mime is! String || hls is! bool) {
      return null;
    }
    // 台帳は端末内の保存値でも、取りに行く先は改めて確かめる（http/https 以外は戻さない）
    if (!isWebUrl(url) || !hasListedExtension(name)) return null;
    final t = WebTransferTask(
      id: id,
      lib: lib,
      url: url,
      headers: headers is Map
          ? {
              for (final h in headers.entries)
                if (h.key is String && h.value is String)
                  h.key as String: h.value as String,
            }
          : const {},
      hls: hls,
      name: name,
      mime: mime,
    );
    // 端末内の保存値でも型は信用しない。読めない項目は無かったものとして扱う
    int n(String k) {
      final v = e[k];
      return v is num ? v.toInt() : 0;
    }

    String? str(String k) {
      final v = e[k];
      return v is String ? v : null;
    }

    t.size = n('size');
    t.hlsSeg = n('hlsSeg');
    t.hlsBytes = n('hlsBytes');
    t.hlsTotal = n('hlsTotal');
    t.keyAttempt = n('keyAttempt');
    t.hlsVariant = str('hlsVariant');
    t.pendingKey = str('pendingKey');
    final file = _stagePath(dir, t);
    final exists = await file.exists();
    if (e['fetched'] == true) {
      if (exists && await file.length() > 0) {
        t.staged = file;
        t.loaded = 0;
      } else {
        // 取り終えたはずの一時ファイルが消えていた。最初から取り直す
        t.hlsSeg = 0;
        t.hlsBytes = 0;
        t.hlsVariant = null;
        t.loaded = 0;
      }
    } else if (hls && exists) {
      // 台帳を書いた後に追記されたセグメントは数に入っていない。記録した所まで切り詰めて、そこから続ける
      final len = await file.length();
      if (len > t.hlsBytes) {
        final raf = await file.open(mode: FileMode.append);
        try {
          await raf.truncate(t.hlsBytes);
        } finally {
          await raf.close();
        }
      }
      t.loaded = t.hlsSeg;
    } else if (exists) {
      t.loaded = await file.length();
    }
    switch (e['status']) {
      case 'paused':
        t.status = WebTaskStatus.paused;
      case 'error':
        t.status = WebTaskStatus.error;
        t.error = str('error') ?? '前回の起動で取り込みに失敗しました';
      default:
        // 取得中・送信中・順番待ちだった行は、落とされた所から自動で続ける
        t.status = WebTaskStatus.queued;
    }
    return t;
  }

  // 台帳に無い一時ファイルは誰も使わないので消す
  Future<void> _sweepUnreferenced() async {
    final dir = _dir;
    if (dir == null || _persistentDirFn == null) return;
    final keep = {for (final t in _tasks) _stagePath(dir, t).path};
    try {
      await for (final f in dir.list()) {
        if (f is File && !keep.contains(f.path)) await f.delete();
      }
    } on FileSystemException catch (e) {
      debugPrint('web stage sweep skipped: $e');
    }
  }

  /// 書き込みは順番に。中身は書く直前の状態から作るので、後の書き込みが常に最新を持つ。
  /// 前回の台帳を読み終えるまでは書かない（読む前に上書きすると前回の取り込みが消える）。
  /// 完了の書き込み待ちの行（[_completing]）は載せない。前の行の完了を、後の書き込みが
  /// 「転送中」のまま書き戻さんようにするため（マイクロタスクの順番に頼らない）
  Future<void> _persist({bool requireSuccess = false}) {
    final ledger = this.ledger;
    if (ledger == null || _disposed) return Future.value();
    _lastPersistMs = DateTime.now().millisecondsSinceEpoch;
    final waitRestore = _restoreDone ? null : restore();
    final write = _persistChain.then((_) async {
      if (waitRestore != null) await waitRestore;
      // 読めなかった台帳には書かない（前回分を空で上書きせんため）。この起動では落とされた後の
      // 再開が効かんだけなので、取り込み自体は止めない。止めると読めん間ずっと取り込めなくなる
      if (_ledgerUnreadable || _disposed) return;
      final snapshot = jsonEncode([
        for (final t in _tasks)
          if (!_completing.contains(t) &&
              (t.active ||
                  t.status == WebTaskStatus.paused ||
                  t.status == WebTaskStatus.error))
            t.toLedger(),
      ]);
      try {
        await ledger.write(snapshot);
      } on Exception catch (e) {
        // 進捗の記録は次で取り戻せるが、送信前と完了の記録は失敗したまま進めない。
        debugPrint('web ledger not saved: $e');
        if (requireSuccess) throw StateError('転送状態を保存できません。再試行してください');
      }
    });
    // 呼び出し側には失敗を返すが、後の再試行まで失敗した Future に連鎖させない。
    _persistChain = write.then((_) {}, onError: (Object _) {});
    return write;
  }

  // HLS はセグメントごとに進むので、記録は間引く（戻す時は記録した所まで切り詰めるので古くても壊れない）
  void _persistSoon() {
    if (DateTime.now().millisecondsSinceEpoch - _lastPersistMs >= 1000) {
      unawaited(_persist());
    }
  }

  /// 同じ保存先へ同じ URL から取り込み済みで、そのファイルが今も R2 に残っていれば、その記録を返す。
  /// 見分けは URL の完全一致だけ。名前や大きさだけで比べると別の動画を止めてしまうため。
  /// 確かめられない時（通信失敗など）は null を返し、今まで通り取り込ませる。
  Future<WebHistoryEntry?> findDuplicate(String lib, String url) async {
    final List<WebHistoryEntry> entries;
    try {
      entries = await history.list();
    } catch (e) {
      debugPrint('web history not readable for duplicate check: $e');
      return null;
    }
    for (final e in entries) {
      if (e.url != url || e.key.isEmpty) continue;
      // 保存先を記録する前の履歴は、別のライブラリの取り込みかもしれない。大きさまで同じ時だけ同じものとみなす
      if (e.lib.isNotEmpty && e.lib != lib) continue;
      try {
        final now = await api.objectAt(lib, e.key);
        if (now == null) continue;
        // 消した後に同じ名前の別ファイルが置かれた時は、大きさが違うので止めない
        if (now.size != null && e.size > 0 && now.size != e.size) continue;
        if (e.lib.isEmpty && (now.size == null || now.size != e.size)) continue;
        return e;
      } catch (err) {
        debugPrint('duplicate check skipped: $err');
        return null;
      }
    }
    return null;
  }

  void cancel(String id) {
    final t = _find(id);
    if (t == null || !(t.active || t.status == WebTaskStatus.paused)) return;
    t.pauseRequested = false;
    if (t.cancel == null || t.status == WebTaskStatus.paused) {
      t.cancel = null;
      unawaited(_dropStaged(t));
      t.status = WebTaskStatus.cancelled;
      _changed();
      unawaited(_persist());
      _pump();
      return;
    }
    t.cancel!.cancel('user');
  }

  /// 一時停止。取り消しと違い、端末に落とせた分は残して再開で続きから取る。
  void pause(String id) {
    final t = _find(id);
    if (t == null || !t.active) return;
    t.pauseRequested = true;
    if (t.cancel == null) {
      t.status = WebTaskStatus.paused;
      _changed();
      unawaited(_persist());
      _pump();
      return;
    }
    t.cancel!.cancel('pause');
  }

  void resume(String id) {
    final t = _find(id);
    if (t == null || t.status != WebTaskStatus.paused) return;
    t.pauseRequested = false;
    t.status = WebTaskStatus.queued;
    t.cancel = null;
    _changed();
    unawaited(_persist());
    _pump();
  }

  /// 失敗・取り消しの行をやり直す。途中まで落とせていれば続きから取る。
  void retry(String id) {
    final t = _find(id);
    if (t == null ||
        (t.status != WebTaskStatus.error &&
            t.status != WebTaskStatus.cancelled)) {
      return;
    }
    if (!hasListedExtension(t.name) || !isWebUrl(t.url)) return;
    t.status = WebTaskStatus.queued;
    t.error = null;
    t.cancel = null;
    _changed();
    unawaited(_persist());
    _pump();
  }

  /// 完了・取り消しの1行を一覧から消す。
  void dismiss(String id) {
    final t = _find(id);
    if (t == null ||
        (t.status != WebTaskStatus.done &&
            t.status != WebTaskStatus.cancelled)) {
      return;
    }
    _tasks.remove(t);
    _changed();
  }

  /// 終わった行（完了・失敗・取り消し）を一覧から消す。一時ファイルも消す。
  void clearFinished() {
    final gone = _tasks.where((t) => t.finished).toList();
    _tasks.removeWhere((t) => t.finished);
    for (final t in gone) {
      _dropStaged(t);
    }
    _changed();
    unawaited(_persist());
  }

  /// ここまでに頼んだ台帳の書き込みが終わるまで待つ（テスト用）。
  Future<void> ledgerWritten() async {
    Future<void> last;
    do {
      last = _persistChain;
      await last;
    } while (!identical(last, _persistChain));
  }

  /// 積んだものが全部片付くまで待つ（テスト用）。
  Future<void> idle() {
    if (_running.isEmpty && !_tasks.any((t) => t.status == WebTaskStatus.queued)) {
      return Future.value();
    }
    final c = Completer<void>();
    _idleWaiters.add(c);
    return c.future;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _tasks) {
      t.cancel?.cancel('dispose');
    }
    final d = _ownsDir ? _dir : null;
    if (d != null) {
      unawaited(d.delete(recursive: true).then((_) {}, onError: (Object e) {
        // 消し損ねても次に使う時の _sweepStale が消す
        debugPrint('web stage dir not removed: $e');
      }));
    }
    super.dispose();
  }

  // ---------- 内部 ----------

  WebTransferTask? _find(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _changed() {
    if (_disposed) return;
    _lastNotifyMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  // 進捗はチャンクごとに来るので、描画し直しは間引く
  void _progress() {
    if (DateTime.now().millisecondsSinceEpoch - _lastNotifyMs >= 150) {
      _changed();
    }
  }

  void _pump() {
    for (final t in _tasks) {
      if (_running.length >= parallel) break;
      if (t.status == WebTaskStatus.queued && !_running.contains(t.id)) {
        _running.add(t.id);
        unawaited(_run(t));
      }
    }
    if (_running.isEmpty && !_tasks.any((t) => t.status == WebTaskStatus.queued)) {
      for (final c in _idleWaiters) {
        if (!c.isCompleted) c.complete();
      }
      _idleWaiters.clear();
    }
  }

  Future<void> _run(WebTransferTask t) async {
    final token = CancelToken();
    t.cancel = token;
    try {
      if (t.staged == null) {
        t.status = WebTaskStatus.fetching;
        _changed();
        await _persist(requireSuccess: true);
        t.staged = t.hls ? await _fetchHls(t, token) : await _fetchFile(t, token);
        _checkCancelled(token);
        await _persist(requireSuccess: true);
      }
      t.status = WebTaskStatus.uploading;
      t.loaded = 0;
      _changed();
      await _upload(t, token);
      _checkCancelled(token);
      // 履歴と台帳に完了を書き終えてから完了にする。完了にした途端に転送中の通知（サービス）が外れ、
      // 画面の無いエンジンは畳まれる。書き終える前に畳まれると、次の起動で同じ物を取り直してしまう
      _completing.add(t);
      try {
        await _persist(requireSuccess: true);
        await _record(t);
      } finally {
        _completing.remove(t);
      }
      t.status = WebTaskStatus.done;
      await _dropStaged(t);
    } catch (e) {
      if (token.isCancelled && t.pauseRequested) {
        t.status = WebTaskStatus.paused;
      } else if (_disposed) {
        // キューごと畳まれただけ。一時ファイルと台帳は次の起動の再開に残す
        t.status = WebTaskStatus.cancelled;
      } else if (token.isCancelled) {
        t.status = WebTaskStatus.cancelled;
        await _dropStaged(t);
      } else {
        // 落とせた分は残す。再試行は続きから取る／上げ直すだけで済む
        t.status = WebTaskStatus.error;
        t.error = _describe(e);
      }
    } finally {
      _running.remove(t.id);
      _changed();
      unawaited(_persist());
      _pump();
    }
  }

  void _checkCancelled(CancelToken token) {
    if (token.isCancelled) {
      throw DioException.requestCancelled(
          requestOptions: RequestOptions(), reason: 'cancelled');
    }
  }

  Future<File> _stageFile(WebTransferTask t) async =>
      _stagePath(await _ensureDir(), t);

  Future<Directory> _ensureDir() async {
    var dir = _dir;
    if (dir != null) return dir;
    final persistent = _persistentDirFn;
    if (persistent != null) {
      dir = await persistent();
      if (!await dir.exists()) await dir.create(recursive: true);
      // 一時ファイルを残す置き場へ移ったので、前の版が OS の一時領域に残した置き場はもう誰も使わない
      await _sweepStale();
    } else {
      // 強制終了で残った前回の置き場は誰も使わんので、新しく作る前に掃除する
      await _sweepStale();
      dir = await Directory.systemTemp.createTemp('r2g-web-');
      _ownsDir = true;
    }
    return _dir = dir;
  }

  // 拡張子は名前から引き継ぐ。サムネ抽出などが拡張子を手掛かりにすることがあるため
  File _stagePath(Directory dir, WebTransferTask t) {
    final dot = t.name.lastIndexOf('.');
    return File('${dir.path}/${t.id}${dot < 0 ? '' : t.name.substring(dot)}');
  }

  // 強制終了で残った前回の一時ファイルは誰も使わんので、最初に掃除する
  Future<void> _sweepStale() async {
    try {
      await for (final e in Directory.systemTemp.list()) {
        if (e is Directory && e.uri.pathSegments.any((s) => s.startsWith('r2g-web-'))) {
          await e.delete(recursive: true);
        }
      }
    } on FileSystemException catch (e) {
      // 掃除は失敗しても取り込み自体には影響せん
      debugPrint('web stage sweep skipped: $e');
    }
  }

  Future<void> _dropStaged(WebTransferTask t) async {
    // 取得の途中で止まった部分ファイルは staged に入る前なので、置き場の規則から引く
    final dir = _dir;
    final f = t.staged ?? (dir == null ? null : _stagePath(dir, t));
    t.staged = null;
    t.hlsSeg = 0;
    t.hlsBytes = 0;
    t.hlsVariant = null;
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException catch (e) {
      // 消せなくても次の起動時の掃除で消える
      debugPrint('web staged file not removed: $e');
    }
  }

  bool _isTransient(Object e) {
    if (e is DioException) {
      return e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError ||
          _isTransient(e.error ?? '');
    }
    return e is SocketException || e is HttpException || e is TimeoutException;
  }

  /// 通信が切れた時は少し待って取り直す。ここでは回線の揺れだけを救い、HTTP エラーは救わない。
  Future<R> _withNetRetry<R>(CancelToken token, Future<R> Function() body) async {
    var tries = 0;
    while (true) {
      try {
        return await body();
      } catch (e) {
        if (token.isCancelled || !_isTransient(e) || ++tries > maxNetRetries) {
          rethrow;
        }
        await Future<void>.delayed(retryDelay * tries);
      }
    }
  }

  Future<File> _fetchFile(WebTransferTask t, CancelToken token) async {
    final dest = await _stageFile(t);
    var emptyRetried = false;
    var rangeRestarted = false;
    var netTries = 0;
    while (true) {
      final resumeAt = await dest.exists() ? await dest.length() : 0;
      final raf = await dest.open(mode: FileMode.append);
      try {
        await fetcher.download(
          t.url,
          t.headers,
          resumeAt: resumeAt,
          origin: t.url,
          cancelToken: token,
          onTotal: (n) => t.size = n,
          onChunk: (c) async {
            await raf.writeFrom(c);
          },
          onProgress: (w) {
            t.loaded = w;
            _progress();
          },
        );
      } on RangeUnsupported {
        // 部分ファイルに全体を追記すると壊れるので、最初から取り直す
        await raf.close();
        await dest.delete();
        t.loaded = 0;
        t.size = 0;
        continue;
      } catch (e) {
        await raf.close();
        // 取り終えた直後、台帳に印を書く前に消されると、手元のファイルは全部あるのに続きを頼んで 416 になる。
        // 手元の中身が今の元と同じか確かめる手段が無いので、1回だけ最初から取り直す
        if (e is WebFetchError && e.status == 416 && resumeAt > 0 && !rangeRestarted) {
          rangeRestarted = true;
          await dest.delete();
          t.loaded = 0;
          t.size = 0;
          continue;
        }
        if (!token.isCancelled && _isTransient(e) && ++netTries <= maxNetRetries) {
          await Future<void>.delayed(retryDelay * netTries);
          continue;
        }
        rethrow;
      }
      await raf.close();
      _checkCancelled(token);
      // 0 バイトは取れたことにならん（200 で空ボディが返る通信の揺れ）。1回だけ白紙から取り直す
      if (await dest.length() == 0) {
        if (emptyRetried) throw StateError('empty download');
        emptyRetried = true;
        await dest.delete();
        continue;
      }
      t.size = await dest.length();
      t.loaded = t.size;
      return dest;
    }
  }

  Future<File> _fetchHls(WebTransferTask t, CancelToken token) async {
    final dest = await _stageFile(t);
    // 台帳（hlsBytes）と実ファイルが食い違えば、途中のセグメント境界を推測せず最初からにする
    final actual = await dest.exists() ? await dest.length() : 0;
    if (actual != t.hlsBytes) {
      if (await dest.exists()) await dest.delete();
      t.hlsSeg = 0;
      t.hlsBytes = 0;
      t.loaded = 0;
    }
    Future<String> text(String url) => _withNetRetry(
        token, () => fetcher.fetchText(url, t.headers,
            origin: t.url, cancelToken: token));
    var playlist = t.hlsVariant;
    if (playlist == null) {
      final master = await text(t.url);
      playlist = hlsIsMaster(master) ? (hlsVariant(master, t.url) ?? t.url) : t.url;
    }
    final media = await text(playlist);
    if (hlsIsEncrypted(media)) {
      throw StateError('暗号化されたHLSは保存できません');
    }
    if (hlsNeedsInitSegment(media)) {
      throw StateError('fMP4形式のHLSには未対応です');
    }
    final segs = hlsSegments(media, playlist);
    if (segs.isEmpty) throw StateError('empty playlist');
    t.hlsTotal = segs.length;
    t.hlsVariant = playlist;
    while (t.hlsSeg < segs.length) {
      _checkCancelled(token);
      final bytes = await _withNetRetry(
        token,
        () => fetcher.fetchBytes(segs[t.hlsSeg], t.headers,
            origin: t.url, cancelToken: token),
      );
      // 追記と添字の更新は一組。ここで切れても、次は実サイズとの突き合わせで安全に取り直せる
      await dest.writeAsBytes(bytes, mode: FileMode.append, flush: true);
      t.hlsBytes = await dest.length();
      t.hlsSeg++;
      t.loaded = t.hlsSeg;
      _progress();
      _persistSoon();
    }
    if (await dest.length() == 0) throw StateError('empty download');
    t.size = await dest.length();
    t.loaded = t.size;
    return dest;
  }

  Future<void> _upload(WebTransferTask t, CancelToken token) async {
    final file = t.staged!;
    t.size = await file.length();
    var first = t.keyAttempt < 1 ? 1 : t.keyAttempt;
    // 中断中に他の端末が同名・同サイズの別ファイルを置くことがある。
    // 内容まで一致した時だけ送信済みとみなし、照合できない時は手元の原本を残す。
    String? freeKey;
    final pending = t.pendingKey;
    if (pending != null) {
      final there = await api.objectAt(t.lib, pending);
      _checkCancelled(token);
      if (there == null) {
        freeKey = pending;
      } else if (there.size == t.size &&
          await api.fileMatches(there.url, file, cancelToken: token)) {
        _checkCancelled(token);
        t.key = pending;
        await _thumb(t, file, pending);
        return;
      } else {
        // 落ちている間に別のファイルがその名前に置かれた。次の名前から探す
        first++;
      }
    }
    for (var attempt = first;; attempt++) {
      if (attempt > maxKeyAttempts) {
        throw const ApiError(409, '同じ名前のファイルが多すぎます');
      }
      final key = 'downloads/${suffixedName(t.name, attempt)}';
      if (key != freeKey && await api.objectAt(t.lib, key) != null) {
        _checkCancelled(token);
        continue;
      }
      t.pendingKey = key;
      t.keyAttempt = attempt;
      await _persist(requireSuccess: true);
      try {
        await api.putFile(
          t.lib,
          key,
          file,
          t.mime,
          cancelToken: token,
          onProgress: (sent, total) {
            t.loaded = sent;
            t.size = total;
            _progress();
          },
        );
        t.key = key;
        break;
      } on ApiError catch (e) {
        // 確かめた後に別の送信が同じ名前を取った。自分の物ではないので送り先の記録を外して次の名前へ
        if (e.status == 409 && !token.isCancelled) {
          t.pendingKey = null;
          freeKey = null;
          continue;
        }
        rethrow;
      }
    }
    await _thumb(t, file, t.key!);
  }

  Future<void> _thumb(WebTransferTask t, File file, String key) async {
    final maker = makeThumb;
    if (maker == null) return;
    // サムネが無くても保存自体は成功。一覧を開いた時のバックフィルが後で補う
    try {
      final thumb = await maker(file, t.mime);
      if (thumb != null && thumb.isNotEmpty) {
        await api.putThumb(t.lib, key, thumb);
      }
    } catch (e) {
      debugPrint('web thumb skipped: $e');
    }
  }

  Future<void> _record(WebTransferTask t) async {
    try {
      await history.add(WebHistoryEntry(
        name: t.name,
        key: t.key ?? '',
        url: t.url,
        mime: t.mime,
        size: t.size,
        at: DateTime.now().millisecondsSinceEpoch,
        lib: t.lib,
      ));
    } catch (e) {
      // 履歴は付随の記録。書けなくても取り込みは成功として扱う
      debugPrint('web history not saved: $e');
    }
  }

  String _describe(Object e) {
    if (e is WebFetchError) {
      return e.status == 403
          ? 'HTTP 403（取得を拒否されました。ページを開き直してもう一度試してください）'
          : e.toString();
    }
    if (e is UnsupportedWebUrl) return e.toString();
    if (e is DioException) return e.message ?? 'network error';
    if (e is StateError) return e.message;
    return e.toString();
  }
}
