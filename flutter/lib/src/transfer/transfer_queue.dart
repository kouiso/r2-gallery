import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../offline/offline_store.dart';
import '../store/kv.dart';
import '../webdl/media_name.dart';
import 'transfer_api.dart';

enum TransferStatus { queued, preparing, running, done, error, cancelled, paused }

/// アップロードする元。端末ではピッカーが返したファイル、Web ではメモリ上のバイト列。
class UploadSource {
  final String name;
  final int size;
  final String mime;
  final String? path;
  final Uint8List? bytes;

  /// パスで渡せない元（content:// など）を読む口。再起動後には読み直せない。
  final Stream<List<int>> Function()? reader;
  const UploadSource({
    required this.name,
    required this.size,
    required this.mime,
    this.path,
    this.bytes,
    this.reader,
  });
}

/// 転送1件。KMP 版 TransferTask の up / down に対応する（ネット取り込みは WebTransferQueue）。
class TransferTask {
  TransferTask({
    required this.id,
    required this.kind,
    required this.lib,
    required this.name,
    required this.size,
    required this.mime,
    this.status = TransferStatus.queued,
  });

  final String id;

  /// 'up'（アップロード）か 'down'（オフライン保存）。
  final String kind;
  final String lib;
  final String name;
  int size;
  final String mime;
  int loaded = 0;
  TransferStatus status;
  String? error;

  // アップロード: サーバーが受け付けたキー・multipart の id と確定済みパート
  String? key;
  String? uploadId;
  List<UploadPart> parts = [];
  String? stagedPath;
  String? sourcePath;
  Uint8List? memory;

  // オフライン保存
  String? itemKey;
  String? itemType;
  String? itemUrl;

  /// 前回の起動から引き継いだ行か。
  bool fromLedger = false;

  int _gen = 0;
  CancelToken? _token;
  Stream<List<int>> Function()? _reader;

  bool get isUpload => kind == 'up';

  bool get active =>
      status == TransferStatus.queued ||
      status == TransferStatus.preparing ||
      status == TransferStatus.running;

  bool get finished =>
      status == TransferStatus.done ||
      status == TransferStatus.cancelled ||
      status == TransferStatus.error;

  int get percent {
    if (size <= 0) return 0;
    return (loaded * 100 ~/ size).clamp(0, 100);
  }

  Map<String, Object?> toLedger() => {
        'id': id,
        'kind': kind,
        'lib': lib,
        'name': name,
        'size': size,
        'loaded': loaded,
        'mime': mime,
        'status': status.name,
        if (error != null) 'error': error,
        if (key != null) 'key': key,
        if (uploadId != null) 'uploadId': uploadId,
        if (parts.isNotEmpty) 'parts': [for (final p in parts) p.toJson()],
        if (stagedPath != null) 'stagedPath': stagedPath,
        if (sourcePath != null) 'sourcePath': sourcePath,
        if (itemKey != null) 'itemKey': itemKey,
        if (itemType != null) 'itemType': itemType,
      };
}

/// 台帳（再起動をまたぐ転送の記録）の置き場。テストで差し替える。
abstract class LedgerStore {
  Future<String?> read();
  Future<void> write(String json);
}

class KvLedgerStore implements LedgerStore {
  const KvLedgerStore();
  static const key = 'r2g.transferQueue';
  @override
  Future<String?> read() => Kv.get(key);
  @override
  Future<void> write(String json) => Kv.set(key, json);
}

typedef FileThumbMaker = Future<Uint8List?> Function(File file, String mime);

/// 端末側の転送キュー。KMP 版 TransferQueue の考え方をそのまま持ってくる:
/// 選んだファイルは最初にアプリ専用領域へ退避し、キー・uploadId・確定済みパートを台帳に残す。
/// アプリが落とされても、次の起動で続きのパートから再開できる（バイト列は端末にしか無いので、サーバー側では救えない）。
class TransferQueue extends ChangeNotifier {
  TransferQueue({
    required this.api,
    required this.offline,
    LedgerStore? ledger,
    Future<Directory> Function()? stageDir,
    this.makeThumb,
    this.parallel = 2,
    this.netRetryDelay = const Duration(seconds: 15),
    this.multipartThreshold = ApiClient.multipartThreshold,
    this.partSize = 8 * 1024 * 1024,
    bool? persist,
    bool Function()? configured,
  })  : _ledger = ledger ?? const KvLedgerStore(),
        _stageDirFn = stageDir ?? _defaultStageDir,
        _persistOn = persist ?? !kIsWeb,
        _configured = configured ?? (() => true);

  final TransferApi api;
  final OfflineStore offline;
  final FileThumbMaker? makeThumb;
  final int parallel;
  final Duration netRetryDelay;
  final int multipartThreshold;
  final int partSize;
  final LedgerStore _ledger;
  final Future<Directory> Function() _stageDirFn;
  final bool _persistOn;
  final bool Function() _configured;

  /// 同名キーが既にある時に「name (2)」…「name (9)」まで試す回数（KMP 版と同じ）。
  static const maxKeyAttempts = 9;

  /// 前回の起動から引き継いだが元ファイルを退避できていなかった行の理由（KMP 版と同じ文言）。
  static const lostSourceMessage =
      '転送の中断前にファイルを退避できませんでした。もう一度ファイルを選んでください';

  final List<TransferTask> _tasks = [];
  final Map<String, Future<void>> _workers = {};
  final Map<String, Future<void>> _stagers = {};
  final Map<String, Timer> _waits = {};
  final _done = StreamController<TransferTask>.broadcast();
  final Completer<void> _restored = Completer<void>();
  Future<void> _persistChain = Future.value();
  final Set<TransferTask> _completing = {};
  Directory? _stage;
  int _seq = 0;
  int _lastNotifyMs = 0;
  bool _disposed = false;

  /// 回線が無い間はアップロードを始めず「待機中」にしておく。
  bool online = true;

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  /// 完了した転送。一覧の取り直しに使う。
  Stream<TransferTask> get doneEvents => _done.stream;

  /// 裏で動き続けるべき転送があるか（フォアグラウンドサービスを張る目安）。
  bool get hasActiveWork => _tasks.any((t) => t.active);

  static Future<Directory> _defaultStageDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/transfers');

  Future<Directory> _dir() async {
    final d = _stage ??= await _stageDirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  TransferTask? _find(String id) {
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

  void _progress() {
    if (DateTime.now().millisecondsSinceEpoch - _lastNotifyMs >= 150) _changed();
  }

  // ---------- 台帳 ----------

  /// 書き込みは順番に。後から積んだ書き込みが常に最新の状態を持つ。
  /// 完了の書き込み待ちの行（[_completing]）は、どの書き込みにも載せない。
  /// 2 件が続けて終わった時、後の行の書き込みが前の行を「転送中」のまま書き戻さんようにするため
  Future<void> _persist() {
    if (!_persistOn) return Future.value();
    final snapshot = jsonEncode([
      for (final t in _tasks)
        // メモリ上の元（Web）は再起動で消えるので残しても戻せない
        if (!_completing.contains(t) && t.status != TransferStatus.done && t.memory == null)
          t.toLedger(),
    ]);
    return _persistChain = _persistChain.then((_) async {
      try {
        await _ledger.write(snapshot);
      } on Exception catch (e) {
        // 書けなくても今の転送は続ける。落とされた時に戻せる範囲が狭くなるだけ
        debugPrint('transfer ledger not saved: $e');
      }
    });
  }

  /// 前回の起動の台帳を読み戻す。積む操作はこれが終わるまで待つ（id の重複を避ける）。
  Future<void> restore() async {
    if (_restored.isCompleted) return;
    try {
      await _restoreLedger();
    } on Exception catch (e) {
      debugPrint('transfer ledger not restored: $e');
    }
    _restored.complete();
    _changed();
    _pump();
  }

  Future<void> _restoreLedger() async {
    if (!_persistOn) return;
    final raw = await _ledger.read();
    final restored = <TransferTask>[];
    if (raw != null) {
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException catch (e) {
        debugPrint('transfer ledger unreadable: $e');
      }
      if (decoded is List) {
        for (final e in decoded) {
          final t = await _fromLedger(e);
          if (t != null) restored.add(t);
        }
      }
    }
    _tasks.addAll(restored);
    // 台帳から外れた退避ファイルは誰も使わないので消す
    final keep = {for (final t in restored) ?t.stagedPath};
    try {
      final dir = await _dir();
      await for (final f in dir.list()) {
        if (f is File && !keep.contains(f.path)) await f.delete();
      }
    } on Exception catch (e) {
      debugPrint('transfer stage sweep skipped: $e');
    }
    for (final t in restored) {
      if (t.status == TransferStatus.preparing) _startStage(t);
    }
    if (restored.isNotEmpty) await _persist();
  }

  Future<TransferTask?> _fromLedger(Object? e) async {
    if (e is! Map) return null;
    final id = e['id'], kind = e['kind'], lib = e['lib'], name = e['name'];
    if (id is! String || kind is! String || lib is! String || name is! String) {
      return null;
    }
    final m = RegExp(r'^[ud](\d+)$').firstMatch(id);
    if (m != null) {
      final n = int.parse(m.group(1)!);
      if (n > _seq) _seq = n;
    }
    final saved = e['status'];
    final TransferStatus status;
    switch (saved) {
      case 'error':
        status = TransferStatus.error;
      case 'paused':
        status = TransferStatus.paused;
      case 'cancelled' || 'done':
        return null;
      default:
        // 動いていた行は待機に戻す。失敗の行は勝手に生き返らせない
        status = TransferStatus.queued;
    }
    final size = e['size'], loaded = e['loaded'], mime = e['mime'];
    final t = TransferTask(
      id: id,
      kind: kind,
      lib: lib,
      name: name,
      size: size is num ? size.toInt() : 0,
      mime: mime is String ? mime : 'application/octet-stream',
      status: status,
    )..fromLedger = true;
    final err = e['error'];
    if (status == TransferStatus.error && err is String) t.error = err;
    if (kind == 'down') {
      final ik = e['itemKey'], it = e['itemType'];
      if (ik is! String) return null;
      t.itemKey = ik;
      t.itemType = it is String ? it : 'image';
      return t;
    }
    if (kind != 'up') return null;
    final staged = e['stagedPath'], source = e['sourcePath'];
    final key = e['key'], uploadId = e['uploadId'], parts = e['parts'];
    var stagedOk = false;
    if (staged is String) {
      final f = File(staged);
      // ピッカーがサイズ不明（-1/0）を返した時は、退避した実ファイルだけがサイズの正解
      stagedOk = await f.exists() && (t.size <= 0 || await f.length() == t.size);
      if (stagedOk && t.size <= 0) t.size = await f.length();
    }
    if (stagedOk) {
      t.stagedPath = staged as String;
      t.loaded = loaded is num ? loaded.toInt() : 0;
      if (key is String) t.key = key;
      if (uploadId is String) t.uploadId = uploadId;
      if (parts is List) {
        t.parts = [for (final p in parts) ?UploadPart.fromJson(p)];
      }
      return t;
    }
    if (source is String && await File(source).exists()) {
      // 退避の途中で落とされた。元のファイルがまだあるので退避からやり直す
      t.sourcePath = source;
      if (status != TransferStatus.paused) t.status = TransferStatus.preparing;
      return t;
    }
    t.status = TransferStatus.error;
    t.error = lostSourceMessage;
    return t;
  }

  // ---------- 積む ----------

  /// 選んだファイルをアップロードに積む。退避が済んだものから順に送る。
  Future<List<TransferTask>> enqueueUploads(
      String lib, List<UploadSource> sources) async {
    await _restored.future;
    final added = <TransferTask>[];
    for (final s in sources) {
      final t = TransferTask(
        id: 'u${++_seq}',
        kind: 'up',
        lib: lib,
        name: normalizeUploadName(s.name, s.mime),
        size: s.size,
        mime: s.mime,
        status: TransferStatus.preparing,
      )
        ..sourcePath = s.path
        ..memory = s.bytes
        .._reader = s.reader;
      if (t.memory != null) {
        t.size = t.memory!.length;
        t.status = TransferStatus.queued;
      } else if (t.sourcePath == null && t._reader == null) {
        t.status = TransferStatus.error;
        t.error = 'ファイルを読み込めませんでした';
      }
      _tasks.add(t);
      added.add(t);
    }
    await _persist();
    for (final t in added) {
      if (t.status == TransferStatus.preparing) _startStage(t);
    }
    _changed();
    _pump();
    return added;
  }

  /// 選んだ写真・動画をオフライン保存に積む。保存済みのものと積んだばかりのものは積み直さない。
  Future<List<TransferTask>> enqueueDownloads(
      String lib, List<MediaItem> items) async {
    await _restored.future;
    final pending = {
      for (final t in _tasks)
        if (t.kind == 'down' && !t.finished) '${t.lib}\u0000${t.itemKey}',
    };
    final added = <TransferTask>[];
    for (final it in items) {
      final l = it.lib ?? lib;
      if (!pending.add('$l\u0000${it.key}')) continue;
      if (await offline.has(l, it.key)) continue;
      final t = TransferTask(
        id: 'd${++_seq}',
        kind: 'down',
        lib: l,
        name: it.name,
        size: it.size ?? 0,
        mime: it.isVideo ? 'video/mp4' : 'image/*',
      )
        ..itemKey = it.key
        ..itemType = it.type
        ..itemUrl = it.url;
      _tasks.add(t);
      added.add(t);
    }
    if (added.isEmpty) return added;
    await _persist();
    _changed();
    _pump();
    return added;
  }

  // ---------- 退避 ----------

  void _startStage(TransferTask t) {
    if (_stagers.containsKey(t.id)) return;
    final f = _stageOne(t);
    _stagers[t.id] = f;
    f.whenComplete(() {
      if (_stagers[t.id] == f) _stagers.remove(t.id);
      _changed();
      _pump();
    });
  }

  Future<void> _stageOne(TransferTask t) async {
    final src = t.sourcePath;
    final reader = t._reader;
    if (src == null && reader == null) return;
    try {
      final dest = File('${(await _dir()).path}/up-${t.id}.bin');
      if (src != null) {
        await File(src).copy(dest.path);
      } else {
        final sink = dest.openWrite();
        try {
          await sink.addStream(reader!());
        } finally {
          await sink.close();
        }
      }
      final len = await dest.length();
      if (t.size > 0 && len != t.size) {
        await dest.delete();
        throw const FileSystemException('size mismatch');
      }
      if (t.size <= 0) t.size = len;
      if (t.status == TransferStatus.cancelled) {
        // 取り消しが先に片付いていたら、この退避は誰にも使われない
        if (_find(t.id) == null) await dest.delete();
        return;
      }
      // 退避が済んだことは止めても残す（再開でコピーし直さない）
      t.stagedPath = dest.path;
      if (t.status == TransferStatus.preparing) t.status = TransferStatus.queued;
    } on Exception catch (e) {
      if (t.status == TransferStatus.preparing) {
        t.status = TransferStatus.error;
        t.error = 'ファイルを端末に退避できませんでした（${e is FileSystemException ? e.message : e}）';
      }
    }
    await _persist();
  }

  // ---------- 実行 ----------

  void _pump() {
    if (_disposed || !_restored.isCompleted || !online || !_configured()) return;
    for (final t in _tasks) {
      if (_workers.length >= parallel) break;
      if (t.status != TransferStatus.queued || _workers.containsKey(t.id)) continue;
      if (_waits.containsKey(t.id)) continue;
      final gen = ++t._gen;
      t.status = TransferStatus.running;
      t.error = null;
      final f = _run(t, gen);
      _workers[t.id] = f;
      f.whenComplete(() {
        if (_workers[t.id] == f) _workers.remove(t.id);
        _changed();
        _pump();
      });
    }
  }

  /// 後から積んだ一時停止・取り消し・再開が勝つ。古い実行は状態を書き換えない。
  bool _owns(TransferTask t, int gen) => t._gen == gen;

  Future<void> _run(TransferTask t, int gen) async {
    final token = CancelToken();
    t._token = token;
    _changed();
    try {
      if (t.isUpload) {
        await _upload(t, token);
      } else {
        await _download(t, token);
      }
      // サーバーが受け取った後は、止める操作より完了を優先する（KMP 版と同じ）
      if (t.status == TransferStatus.cancelled) return;
      if (t.isUpload) await _thumb(t);
      // 台帳から外し終えてから完了にする。完了にした途端に転送中の通知（サービス）が外れ、
      // 画面を消された後なら残しておいたエンジンも畳まれる。書き終える前に畳まれると次の起動で送り直してしまう
      _completing.add(t);
      try {
        await _persist();
      } finally {
        _completing.remove(t);
      }
      t.status = TransferStatus.done;
      t.loaded = t.size;
      await _dropStaged(t);
      if (!_done.isClosed) _done.add(t);
    } catch (e) {
      if (token.isCancelled || !_owns(t, gen)) {
        // 止めた側（一時停止・取り消し）が状態を決めている
        await _persist();
        return;
      }
      if (_isNetwork(e)) {
        // 回線の問題は失敗にせず待機に戻し、少し後か接続の回復で自動で再開する
        t.status = TransferStatus.queued;
        _waits[t.id]?.cancel();
        _waits[t.id] = Timer(netRetryDelay, () {
          _waits.remove(t.id);
          _pump();
        });
      } else {
        t.status = TransferStatus.error;
        t.error = _describe(e, upload: t.isUpload);
      }
      await _persist();
    }
  }

  bool _isNetwork(Object e) {
    if (e is ApiError) return e.status == 0;
    if (e is DioException) return e.response == null;
    return e is SocketException || e is TimeoutException || e is HttpException;
  }

  String _describe(Object e, {required bool upload}) {
    if (e is ApiError) {
      return switch (e.status) {
        403 when upload => 'このライブラリには書き込めません（HTTP 403）',
        404 => '見つかりませんでした（HTTP 404）',
        409 => '同じ名前のファイルが多すぎます（HTTP 409）',
        _ => e.toString(),
      };
    }
    if (e is FileSystemException) return 'ファイルを読めませんでした（${e.message}）';
    return e.toString();
  }

  void _checkCancelled(CancelToken token) {
    if (token.isCancelled) {
      throw DioException.requestCancelled(
          requestOptions: RequestOptions(), reason: 'cancelled');
    }
  }

  Future<int> _sourceSize(TransferTask t) async {
    final mem = t.memory;
    if (mem != null) return mem.length;
    final p = t.stagedPath;
    if (p == null) throw const FileSystemException('not staged');
    return File(p).length();
  }

  Future<Uint8List> _readAll(TransferTask t) async =>
      t.memory ?? await File(t.stagedPath!).readAsBytes();

  Future<Uint8List> _readChunk(TransferTask t, int offset, int len) async {
    final mem = t.memory;
    if (mem != null) return Uint8List.sublistView(mem, offset, offset + len);
    final raf = await File(t.stagedPath!).open();
    try {
      await raf.setPosition(offset);
      // read は要求より短く返ることがある。足りんまま送ると壊れたファイルになる
      final buf = Uint8List(len);
      var got = 0;
      while (got < len) {
        final n = await raf.readInto(buf, got, len);
        if (n <= 0) throw const FileSystemException('file ended unexpectedly');
        got += n;
      }
      return buf;
    } finally {
      await raf.close();
    }
  }

  Future<void> _upload(TransferTask t, CancelToken token) async {
    final size = await _sourceSize(t);
    t.size = size;
    if (t.key == null) {
      await _freshUpload(t, token, size);
    } else {
      await _resumeUpload(t, token, size, t.key!);
    }
  }

  /// 初回: 409（同名あり）なら「name (2)」…と名前を変えて試す。キーはサーバーが受け付けてから確定する。
  Future<void> _freshUpload(TransferTask t, CancelToken token, int size) async {
    for (var attempt = 1;; attempt++) {
      _checkCancelled(token);
      final key = suffixedName(t.name, attempt);
      try {
        if (size > multipartThreshold) {
          final id = await api.multipartCreate(t.lib, key, t.mime);
          // uploadId の確定は区切り。残さんと再開時に2つ目のセッションを作り、1つ目がサーバーに残る
          t.key = key;
          t.uploadId = id;
          t.parts = [];
          await _persist();
        } else {
          final bytes = await _readAll(t);
          _checkCancelled(token);
          await api.putObject(t.lib, key, bytes, t.mime,
              cancelToken: token, onProgress: (s) {
            t.loaded = s;
            _progress();
          });
          t.key = key;
          await _persist();
          return;
        }
      } on ApiError catch (e) {
        if (e.status == 409 && attempt < maxKeyAttempts && !token.isCancelled) {
          continue;
        }
        rethrow;
      }
      await _multipart(t, token, size);
      return;
    }
  }

  /// 再開: キーは台帳で確定済み。ここでの 409 は前回の完了が届いていたということ。
  Future<void> _resumeUpload(
      TransferTask t, CancelToken token, int size, String key) async {
    if (size <= multipartThreshold) {
      try {
        await api.putObject(t.lib, key, await _readAll(t), t.mime,
            cancelToken: token, onProgress: (s) {
          t.loaded = s;
          _progress();
        });
      } on ApiError catch (e) {
        if (e.status != 409) rethrow;
      }
      return;
    }
    final existing = t.uploadId;
    if (existing != null) {
      try {
        await _multipart(t, token, size);
        return;
      } on ApiError catch (e) {
        // サーバー側で uploadId が失効している。作り直して最初から送る
        if (e.status < 400) rethrow;
        try {
          await api.multipartAbort(t.lib, key, existing);
        } on ApiError catch (abortErr) {
          debugPrint('stale multipart not aborted: $abortErr');
        }
        t.uploadId = null;
        t.parts = [];
        t.loaded = 0;
        await _persist();
      }
    }
    _checkCancelled(token);
    try {
      t.uploadId = await api.multipartCreate(t.lib, key, t.mime);
    } on ApiError catch (e) {
      if (e.status == 409) return;
      rethrow;
    }
    await _persist();
    await _multipart(t, token, size);
  }

  Future<void> _multipart(TransferTask t, CancelToken token, int size) async {
    final uploadId = t.uploadId!;
    final key = t.key!;
    final total = (size + partSize - 1) ~/ partSize;
    for (var n = 1; n <= total; n++) {
      _checkCancelled(token);
      if (t.parts.any((p) => p.partNumber == n)) continue;
      final offset = (n - 1) * partSize;
      final len = offset + partSize > size ? size - offset : partSize;
      final chunk = await _readChunk(t, offset, len);
      final confirmed = _confirmedBytes(t, size);
      final part = await api.putPart(t.lib, key, uploadId, n, chunk,
          cancelToken: token, onProgress: (s) {
        final v = confirmed + s;
        if (v > t.loaded) t.loaded = v > size ? size : v;
        _progress();
      });
      // 確定したパートは止めても残す。再開ではここから先だけ送る
      t.parts = [...t.parts.where((p) => p.partNumber != part.partNumber), part];
      t.loaded = _confirmedBytes(t, size);
      await _persist();
      _changed();
    }
    _checkCancelled(token);
    final sorted = [...t.parts]..sort((a, b) => a.partNumber.compareTo(b.partNumber));
    await api.multipartComplete(t.lib, key, uploadId, sorted);
  }

  int _confirmedBytes(TransferTask t, int size) {
    final v = t.parts.length * partSize;
    return v > size ? size : v;
  }

  Future<void> _thumb(TransferTask t) async {
    final maker = makeThumb;
    final path = t.stagedPath;
    final key = t.key;
    if (maker == null || path == null || key == null) return;
    if (!t.mime.startsWith('image/') && !t.mime.startsWith('video/')) return;
    // サムネが無くても保存自体は成功。一覧のバックフィルが後で補う
    try {
      final thumb = await maker(File(path), t.mime);
      if (thumb != null && thumb.isNotEmpty) await api.putThumb(t.lib, key, thumb);
    } on Exception catch (e) {
      debugPrint('upload thumb skipped: $e');
    }
  }

  Future<void> _download(TransferTask t, CancelToken token) async {
    // 署名URLは期限が切れる。引き継いだ行や 403 は一覧から取り直す
    var url = t.itemUrl ?? await _resign(t);
    Future<Uint8List> fetch(String u) => api.fetchBytes(u, cancelToken: token,
            onProgress: (got, total) {
          if (total > 0) t.size = total;
          t.loaded = got;
          _progress();
        });
    Uint8List bytes;
    try {
      bytes = await fetch(url);
    } on ApiError catch (e) {
      if (e.status != 403 || token.isCancelled) rethrow;
      url = await _resign(t);
      bytes = await fetch(url);
    }
    _checkCancelled(token);
    if (bytes.isEmpty) throw const ApiError(0, 'empty download');
    t.size = bytes.length;
    await offline.saveBytes(
      lib: t.lib,
      key: t.itemKey!,
      type: t.itemType ?? 'image',
      name: t.name,
      plain: bytes,
    );
  }

  Future<String> _resign(TransferTask t) async {
    final url = await api.itemUrl(t.lib, t.itemKey!);
    if (url == null) throw ApiError(404, 'item gone: ${t.itemKey}');
    t.itemUrl = url;
    return url;
  }

  Future<void> _dropStaged(TransferTask t) async {
    final p = t.stagedPath;
    t.stagedPath = null;
    t.memory = null;
    if (p == null) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } on FileSystemException catch (e) {
      // 消し損ねても次の起動時の掃除で消える
      debugPrint('staged upload not removed: $e');
    }
  }

  // ---------- 操作 ----------

  /// 一時停止。退避したファイル・uploadId・確定済みパートは残し、再開で続きから送る。
  void pause(String id) {
    final t = _find(id);
    if (t == null || !t.active) return;
    t._gen++;
    t.status = TransferStatus.paused;
    _waits.remove(id)?.cancel();
    t._token?.cancel('paused');
    _persist();
    _changed();
    _pump();
  }

  void resume(String id) {
    final t = _find(id);
    if (t == null || t.status != TransferStatus.paused) return;
    t._gen++;
    _requeue(t);
  }

  /// 失敗・取り消しの行をやり直す。
  void retry(String id) {
    final t = _find(id);
    if (t == null ||
        (t.status != TransferStatus.error &&
            t.status != TransferStatus.cancelled)) {
      return;
    }
    if (!_recoverable(t)) return;
    t._gen++;
    t.error = null;
    if (t.isUpload && t.uploadId == null) t.loaded = 0;
    _requeue(t);
  }

  /// 失敗した行をまとめてやり直す。接続の回復やアプリへの復帰で呼ぶ（KMP 版と同じ）。
  void retryAllFailed() {
    for (final t in _tasks.toList()) {
      if (t.status == TransferStatus.error) retry(t.id);
    }
  }

  /// 元ファイルが無くて戻せない行は、理由を残したまま触らない。
  bool _recoverable(TransferTask t) =>
      !t.isUpload ||
      t.stagedPath != null ||
      t.memory != null ||
      t.sourcePath != null ||
      t._reader != null;

  void _requeue(TransferTask t) {
    if (t.isUpload && t.stagedPath == null && t.memory == null) {
      t.status = TransferStatus.preparing;
      _startStage(t);
    } else {
      t.status = TransferStatus.queued;
    }
    _persist();
    _changed();
    _pump();
  }

  /// 取り消し。動いている処理が止まるのを待ってから、退避ファイルと multipart を片付けて行を消す。
  Future<void> cancel(String id) async {
    final t = _find(id);
    if (t == null || t.status == TransferStatus.done) return;
    final gen = ++t._gen;
    t.status = TransferStatus.cancelled;
    _waits.remove(id)?.cancel();
    t._token?.cancel('cancelled');
    _changed();
    final worker = _workers[id] ?? _stagers[id];
    if (worker != null) await worker;
    // 待っている間にやり直しが入ったら、その行はもう取り消しではない
    if (t._gen != gen) return;
    await _cleanup(t);
    _tasks.remove(t);
    await _persist();
    _changed();
    _pump();
  }

  Future<void> _cleanup(TransferTask t) async {
    await _dropStaged(t);
    final key = t.key, uploadId = t.uploadId;
    if (key != null && uploadId != null && t.status != TransferStatus.done) {
      try {
        await api.multipartAbort(t.lib, key, uploadId);
      } on ApiError catch (e) {
        // 片付け損ねたセッションは R2 側の期限で消える
        debugPrint('multipart not aborted: $e');
      }
    }
  }

  /// 完了・取り消しの行を一覧から消す。
  void dismiss(String id) {
    final t = _find(id);
    if (t == null ||
        (t.status != TransferStatus.done &&
            t.status != TransferStatus.cancelled)) {
      return;
    }
    _tasks.remove(t);
    _persist();
    _changed();
  }

  /// 終わった行（完了・失敗・取り消し）をまとめて消す。失敗の行の退避ファイルも片付ける。
  Future<void> clearFinished() async {
    final gone = _tasks.where((t) => t.finished).toList();
    _tasks.removeWhere((t) => t.finished);
    _changed();
    for (final t in gone) {
      await _cleanup(t);
    }
    await _persist();
  }

  /// 止まっている待ちを解いて流し直す（アプリへの復帰・接続の後）。
  void wake() {
    for (final w in _waits.values) {
      w.cancel();
    }
    _waits.clear();
    _pump();
  }

  void setOnline(bool value) {
    if (online == value) return;
    online = value;
    if (value) {
      wake();
    }
    _changed();
  }

  /// 動いているものが片付くまで待つ（テスト用）。
  Future<void> idle() async {
    while (_workers.isNotEmpty || _stagers.isNotEmpty) {
      await Future.wait([..._workers.values, ..._stagers.values]);
    }
    await _persistChain;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _tasks) {
      t._token?.cancel('dispose');
    }
    for (final w in _waits.values) {
      w.cancel();
    }
    _waits.clear();
    _done.close();
    super.dispose();
  }
}
