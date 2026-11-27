import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../offline/offline_store.dart';
import '../state/pairing.dart';
import '../store/kv.dart';
import '../store/private_storage.dart';
import '../upload/image_thumb.dart';
import '../webdl/media_name.dart';
import 'multipart_sender.dart';
import 'net_policy.dart';
import 'net_state.dart';
import 'transfer_api.dart';
import 'transfer_ledger.dart';
import 'upload_picker.dart';

enum TransferStatus { queued, preparing, running, done, error, cancelled, paused }

/// 送っている途中で接続が替わり、その行が動けなくなった印。失敗ではなく待機に戻す
class _ConnSwitched implements Exception {
  const _ConnSwitched();
}

/// アップロードする元。端末ではピッカーが返したファイル、Web ではメモリ上のバイト列。
class UploadSource {
  final String name;
  final int size;
  final String mime;
  final String? path;

  /// Android の content:// URI。写しを作らないピッカーの元。権利は画面が生きている間だけ
  final String? uri;
  final Uint8List? bytes;

  /// パスで渡せない元（content:// など）を読む口。再起動後には読み直せない。
  final Stream<List<int>> Function()? reader;

  /// 確認シートの重複確認で計算した中身の SHA-256（16進）。計算しなかった物は null。
  final String? sha256;
  const UploadSource({
    required this.name,
    required this.size,
    required this.mime,
    this.path,
    this.uri,
    this.bytes,
    this.reader,
    this.sha256,
  });

  UploadSource withSha256(String? hash) => UploadSource(
      name: name,
      size: size,
      mime: mime,
      path: path,
      uri: uri,
      bytes: bytes,
      reader: reader,
      sha256: hash);
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

  /// Android の content:// の元。再起動すると読む権利が切れて戻せないので、
  /// 台帳へ書いておき、戻せなかった時に「もう一度選んでください」の失敗行へする
  String? sourceUri;
  Uint8List? memory;

  /// 重複確認で計算済みの中身のハッシュ。一括PUTの時だけ Worker へ添える。
  String? sha256;

  /// この行を積んだ時の接続。切り替えた後は別の送り先へ送らない・abort も元の接続へ
  /// 送るために覚えておく（#149）。台帳は端末の秘密置き場なのでトークンを置いてよい
  String? connEndpoint;
  String? connToken;

  /// アップロード時に選んだ入れ先アルバム（#102）。確定したキーで1回だけ入れる
  String? albumId;

  /// albumId への追加が済んだか。追加前に消された時は次の起動で入れ直す手掛かり
  bool albumAdded = false;

  /// 上げるのは済んだがアルバムへの追加だけ失敗した理由。失敗の行にせず完了のまま残す
  String? albumError;

  // オフライン保存
  String? itemKey;
  String? itemType;
  String? itemUrl;

  /// 転送の記録（ledger）に保存しない（itemUrl と同じ）。
  String? itemViewUrl;

  /// 転送の記録（ledger）に 'viewCopy': true で保存する（false の時は書かない）。
  bool viewCopy = false;

  String? offlineAccountId;

  /// 前回の起動から引き継いだ行か。
  bool fromLedger = false;

  /// 一覧から外した行。書く時に記録から消す判断に使う
  bool _gone = false;

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
        if (sourceUri != null) 'sourceUri': sourceUri,
        'sha256': ?sha256,
        if (itemKey != null) 'itemKey': itemKey,
        if (itemType != null) 'itemType': itemType,
        if (connEndpoint != null) 'connEndpoint': connEndpoint,
        if (albumId != null) 'albumId': albumId,
        if (albumAdded) 'albumAdded': true,
        if (albumError != null) 'albumError': albumError,
        if (offlineAccountId != null) 'offlineAccountId': offlineAccountId,
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

/// content:// の URI から退避先ファイルへ写す口。テストで差し替える
typedef UriStager = Future<void> Function(String uri, String dest);

/// 端末側の転送キュー。KMP 版 TransferQueue の考え方をそのまま持ってくる:
/// 選んだファイルは最初にアプリ専用領域へ退避し、キー・uploadId・確定済みパートを台帳に残す。
/// アプリが落とされても、次の起動で続きのパートから再開できる（バイト列は端末にしか無いので、サーバー側では救えない）。
class TransferQueue extends ChangeNotifier {
  TransferQueue({
    required this.api,
    required this.offline,
    TransferLedger? ledger,
    LedgerStore? legacyLedger,
    SecretKv? secrets,
    Future<Directory> Function()? stageDir,
    this.makeThumb,
    this.parallel = 2,
    this.stageParallel = 2,
    this.uriStager = _defaultUriStager,
    this.thumbTimeout = const Duration(seconds: 20),
    this.netRetryDelay = const Duration(seconds: 15),
    this.stagedDeleteTimeout = const Duration(seconds: 5),
    this.multipartThreshold = ApiClient.multipartThreshold,
    this.partSize = 8 * 1024 * 1024,
    bool? persist,
    bool Function()? configured,
    this.requireDownloadAccount = false,
    this.canUseOfflineAccount,
    this.canDecode,
    Connection? Function()? connOf,
  })  : _ledger = ledger ?? FileTransferLedger(),
        _legacyLedger = legacyLedger ?? const KvLedgerStore(),
        _secrets = secrets ?? const KvSecretKv(),
        _stageDirFn = stageDir ?? _defaultStageDir,
        _persistOn = persist ?? !kIsWeb,
        _configured = configured ?? (() => true),
        _connOf = connOf ?? (() => null);

  final TransferApi api;
  final OfflineStore offline;
  final FileThumbMaker? makeThumb;
  final int parallel;

  /// 端末への写しは同時にこの件数まで。5000件分の写しが一度に走らないように
  final int stageParallel;

  /// Android の content:// を退避先へ写す口（upload_picker channel）。テストでは差し替える
  final UriStager uriStager;

  /// サムネ生成が長引く時に待つ上限。送り自体はサーバーに届いているので進める
  final Duration thumbTimeout;
  final Duration netRetryDelay;
  final Duration stagedDeleteTimeout;
  final int multipartThreshold;
  final int partSize;
  final TransferLedger _ledger;

  /// 旧形式（1つの文字列に全行）の移し元。WebTransferQueue と共用
  final LedgerStore _legacyLedger;

  /// 接続ごとのトークンの置き場（行のファイルには書かない）
  final SecretKv _secrets;
  final Future<Directory> Function() _stageDirFn;
  final bool _persistOn;
  final bool Function() _configured;
  final bool requireDownloadAccount;
  final bool Function(String? accountId, String lib)? canUseOfflineAccount;

  /// 端末が中身を画像として読めるか。試験でだけ差し替える。
  final Future<bool> Function(Uint8List bytes)? canDecode;

  /// いまの接続。行がどの接続の物かを見るのと、abort を正しい送り先へ出すのに使う
  final Connection? Function() _connOf;

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
  final Set<TransferTask> _completing = {};

  /// 接続endpoint→トークン。行の記録には書かず、秘密置き場に1つだけ置く
  final Map<String, String> _conns = {};
  bool _connsDirty = false;

  /// 記録へ書く頼みの番号と、まだ書いていない行
  int _asked = 0;
  int _written = 0;
  final LinkedHashMap<String, TransferTask> _dirty = LinkedHashMap();
  final List<({int at, Completer<void> done})> _waiters = [];
  Future<void>? _ledgerLoop;
  Directory? _stage;
  int _seq = 0;
  int _lastNotifyMs = 0;
  bool _disposed = false;

  /// 端末の回線の様子。合わない行は始めず、走っている行も（オフライン以外は）待機に戻す（#27）。
  /// 既定は「オンラインで Wi‑Fi かは不明」。何も知らせが来ない環境でも止めない
  NetState net = NetState.unknownOnline;

  /// Wi‑Fi 限定の設定。既定は制限なし（設定を変えていない人の動きを変えない）
  TransferNetPolicy policy = const TransferNetPolicy();

  /// アプリが前面か。省データ設定で裏の通信を止められる回線の判定に使う
  bool foreground = true;

  /// 回線があるか。転送バーなどが読む
  bool get online => net.online;

  List<TransferTask> get tasks => List.unmodifiable(_tasks.where((t) =>
      t.isUpload || !requireDownloadAccount || _canSaveOffline(t)));

  bool _canSaveOffline(TransferTask t) => !requireDownloadAccount ||
      (t.offlineAccountId != null &&
       (canUseOfflineAccount?.call(t.offlineAccountId, t.lib) ?? false));

  /// 完了した転送。一覧の取り直しに使う。
  Stream<TransferTask> get doneEvents => _done.stream;

  /// 裏で動き続けるべき転送があるか（フォアグラウンドサービスを張る目安）。
  bool get hasActiveWork => activeWorkCount > 0;

  /// 裏で動かす対象の行の数（待機中を含む）。通知を待機の文言にするかの判定に使う
  int get activeWorkCount => _tasks
      .where((t) => t.active && (t.isUpload || _canSaveOffline(t)))
      .length;

  static Future<Directory> _defaultStageDir() => privatePersistentDirectory('transfers');

  static Future<void> _defaultUriStager(String uri, String dest) =>
      UploadPickerChannel.instance.copyToFile(uri, dest);

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

  /// 完了待ち（サーバーが受け取り済みで、退避ファイルを消している途中）か。画面はこの間ボタンを止める。
  bool isCompleting(String id) => _completing.any((t) => t.id == id);

  /// 操作（一時停止・再開・やり直し・取り消し・一覧から消す）の対象。完了待ちの行は返さない。
  /// 退避パスはもう消えているので、ここで再開・やり直しを通すと退避し直し、done の行に退避ファイルが残る。
  /// 完了待ちに入る前に止めた行（サムネ作成中の一時停止など）も同じなので、入口ごとではなくここで弾く
  TransferTask? _operable(String id) {
    final t = _find(id);
    return t == null || _completing.contains(t) ? null : t;
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

  /// 接続ごとのトークンの秘密置き場のキー
  static const connsKey = Keys.transferConns;

  /// 記録への書き込みは行を名指しで頼み、1本のループが1行ずつ書く。
  /// 頼んだ時点ではなく書く時点の状態で「書く」か「消す」かを決めるので、
  /// 古い頼みが新しい状態を書き戻すことはない（決めた事 3・4）
  Future<void> _persistRows(Iterable<TransferTask> rows) {
    if (!_persistOn) return Future.value();
    for (final t in rows) {
      _dirty[t.id] = t;
    }
    final at = ++_asked;
    final done = Completer<void>();
    _waiters.add((at: at, done: done));
    _ledgerLoop ??= _drainLedger();
    return done.future;
  }

  Future<void> _persist(TransferTask t) => _persistRows([t]);

  Future<void> _drainLedger() async {
    try {
      while (_written < _asked) {
        final upTo = _asked;
        final batch = _dirty.values.toList();
        _dirty.clear();
        for (final t in batch) {
          await _writeOrDrop(t);
        }
        _written = upTo;
        for (var i = _waiters.length - 1; i >= 0; i--) {
          if (_waiters[i].at <= upTo) {
            _waiters[i].done.complete();
            _waiters.removeAt(i);
          }
        }
      }
    } finally {
      _ledgerLoop = null;
    }
  }

  Future<void> _writeOrDrop(TransferTask t) async {
    try {
      // 完了待ち・done・一覧から外した行・メモリ上の元の行は記録から消す
      // （メモリ上の元は再起動で消えるので残しても戻せない）
      if (t._gone ||
          _completing.contains(t) ||
          t.status == TransferStatus.done ||
          t.memory != null) {
        await _ledger.deleteRow(t.id);
      } else {
        await _ledger.writeRow(t.id, jsonEncode(t.toLedger()));
      }
    } catch (e) {
      // 書けなくても今の転送は続ける。落とされた時に戻せる範囲が狭くなるだけ
      debugPrint('transfer ledger not saved: $e');
    }
  }

  /// 接続のトークンは行の記録に書かず、接続ごとの表として秘密置き場に1回だけ書く
  Future<void> _rememberConn(Connection? c) async {
    if (!_persistOn || c == null) return;
    if (_conns[c.endpoint] == c.token) return;
    _conns[c.endpoint] = c.token;
    try {
      await _secrets.set(connsKey, jsonEncode(_conns));
      _connsDirty = false;
    } catch (e) {
      debugPrint('transfer conns not saved: $e');
    }
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

  /// 旧形式（秘密置き場の1つの文字列）の行を、行ごとのファイルへ1回だけ移す。
  /// ファイルが既にある id は新しい形を正として移さない（移す途中で落ちても二重にならない）
  Future<void> _migrateLegacy() async {
    String? raw;
    try {
      raw = await _legacyLedger.read();
    } catch (e) {
      debugPrint('transfer legacy ledger unreadable: $e');
      return;
    }
    if (raw == null || raw == '[]') return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      debugPrint('transfer legacy ledger unreadable: $e');
      return;
    }
    if (decoded is! List) return;
    final existing = {for (final r in await _ledger.readRows()) r['id']};
    for (final e in decoded) {
      if (e is! Map) continue;
      final id = e['id'];
      if (id is! String || existing.contains(id)) continue;
      // 古い行に載っているトークンは接続の表へ移す。行は読み戻し時にトークンを外して書き直す
      final ce = e['connEndpoint'], ct = e['connToken'];
      if (ce is String && ct is String) { _conns[ce] = ct; _connsDirty = true; }
      try {
        await _ledger.writeRow(id, jsonEncode(e));
      } catch (err) {
        debugPrint('transfer ledger migration row failed: $err');
      }
    }
    try {
      await _legacyLedger.write('[]');
    } catch (e) {
      debugPrint('transfer legacy ledger not cleared: $e');
    }
  }

  Future<void> _restoreLedger() async {
    if (!_persistOn) return;
    try {
      final raw = await _secrets.get(connsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            if (e.value is String) _conns[e.key] = e.value as String;
          }
        }
      }
    } catch (e) {
      debugPrint('transfer conns unreadable: $e');
    }
    await _migrateLegacy();
    final restored = <TransferTask>[];
    for (final e in await _ledger.readRows()) {
      final t = await _fromLedger(e);
      if (t != null) restored.add(t);
    }
    // ファイルには並びが無い。id は積んだ順に増えるので数の順で戻す
    restored.sort((a, b) => _idNum(a.id).compareTo(_idNum(b.id)));
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
    // 旧 file_picker の写しはピッカーの置き場に残り続ける。どの行も指さない物は消す（決めた事 12）
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final pd = Directory(
            '${(await getTemporaryDirectory()).path}/file_picker');
        if (await pd.exists()) {
          await for (final f in pd.list()) {
            if (f is File && !keep.contains(f.path)) await f.delete();
          }
        }
      }
    } on Exception catch (e) {
      debugPrint('picker cache sweep skipped: $e');
    }
    // どの行も使っていない接続は表から外す
    final used = {for (final t in restored) ?t.connEndpoint};
    if (_conns.keys.any((e) => !used.contains(e))) {
      _conns.removeWhere((e, _) => !used.contains(e));
      _connsDirty = true;
    }
    if (_connsDirty) {
      try {
        await _secrets.set(connsKey, jsonEncode(_conns));
        _connsDirty = false;
      } catch (e) {
        debugPrint('transfer conns not saved: $e');
      }
    }
    _pumpStage();
    if (restored.isNotEmpty) await _persistRows(restored);
  }

  static int _idNum(String id) {
    final m = RegExp(r'^[ud](\d+)$').firstMatch(id);
    return m == null ? 0 : int.parse(m.group(1)!);
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
    final connE = e['connEndpoint'], connT = e['connToken'];
    if (connE is String) t.connEndpoint = connE;
    if (connT is String) {
      t.connToken = connT;
      // 古い形の行はトークンを持っている。表へ移して行をトークン無しで書き直す
      if (connE is String) { _conns[connE] = connT; _connsDirty = true; }
      _dirty[t.id] = t;
      _asked++;
    } else if (connE is String) {
      t.connToken = _conns[connE];
    }
    final err = e['error'];
    if (status == TransferStatus.error && err is String) t.error = err;
    if (kind == 'down') {
      final ik = e['itemKey'], it = e['itemType'];
      if (ik is! String) return null;
      t.itemKey = ik;
      t.itemType = it is String ? it : 'image';
      t.viewCopy = e['viewCopy'] == true;
      final account = e['offlineAccountId'];
      if (account is String) t.offlineAccountId = account;
      if (requireDownloadAccount && t.offlineAccountId == null) {
        t.status = TransferStatus.error;
        t.error = '保存先アカウントを確認し、もう一度オフライン保存を選んでください';
      }
      return t;
    }
    if (kind != 'up') return null;
    // 古い台帳の行には無い。無ければ添えずに送るだけ
    final hash = e['sha256'];
    if (hash is String) t.sha256 = hash;
    final albumId = e['albumId'], albumErr = e['albumError'];
    if (albumId is String) t.albumId = albumId;
    if (e['albumAdded'] == true) t.albumAdded = true;
    if (albumErr is String) t.albumError = albumErr;
    final staged = e['stagedPath'], source = e['sourcePath'];
    final suri = e['sourceUri'];
    if (suri is String) t.sourceUri = suri;
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
    // content:// の読む権利は画面と一緒に消える。起動をまたいだ行は元へ戻せないので
    // 残しても積み直せない。失敗の行にして、もう一度選び直してもらう
    t.status = TransferStatus.error;
    t.error = lostSourceMessage;
    return t;
  }

  // ---------- 積む ----------

  /// 選んだファイルをアップロードに積む。退避が済んだものから順に送る。
  /// [albumId] はアップロード時に選んだ入れ先（#102）。確定したキーで1回だけ入れる。
  Future<List<TransferTask>> enqueueUploads(
      String lib, List<UploadSource> sources,
      {String? albumId}) async {
    await _restored.future;
    final conn = _connOf();
    await _rememberConn(conn);
    final added = <TransferTask>[];
    for (final s in sources) {
      final t = TransferTask(
        id: 'u${++_seq}',
        kind: 'up',
        lib: lib,
        name: normalizeDeviceName(s.name, s.mime),
        size: s.size,
        mime: s.mime,
        status: TransferStatus.preparing,
      )
        ..sourcePath = s.path
        ..sourceUri = s.uri
        ..memory = s.bytes
        ..sha256 = s.sha256
        ..connEndpoint = conn?.endpoint
        ..connToken = conn?.token
        ..albumId = albumId
        .._reader = s.reader;
      if (t.memory != null) {
        t.size = t.memory!.length;
        t.status = TransferStatus.queued;
      } else if (t.sourcePath == null && t.sourceUri == null && t._reader == null) {
        t.status = TransferStatus.error;
        t.error = 'ファイルを読み込めませんでした';
      }
      _tasks.add(t);
      added.add(t);
    }
    await _persistRows(added);
    _pumpStage();
    _changed();
    _pump();
    return added;
  }

  /// 選んだ写真・動画をオフライン保存に積む。保存済みのものと積んだばかりのものは積み直さない。
  Future<List<TransferTask>> enqueueDownloads(
      String lib, List<MediaItem> items, {OfflineStore? targetStore}) async {
    await _restored.future;
    final store = targetStore ?? offline;
    final pending = {
      for (final t in _tasks)
        if (t.kind == 'down' && !t.finished && t.offlineAccountId == store.accountId)
          '${t.lib}\u0000${t.itemKey}',
    };
    final conn = _connOf();
    await _rememberConn(conn);
    final added = <TransferTask>[];
    for (final it in items) {
      final l = it.lib ?? lib;
      if (!pending.add('$l\u0000${it.key}')) continue;
      if (await store.has(l, it.key)) continue;
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
        ..itemUrl = it.url
        ..itemViewUrl = it.viewUrl
        ..viewCopy = it.viewUrl != null
        ..connEndpoint = conn?.endpoint
        ..connToken = conn?.token
        ..offlineAccountId = store.accountId;
      _tasks.add(t);
      added.add(t);
    }
    if (added.isEmpty) return added;
    unawaited(_persistRows(added));
    _changed();
    _pump();
    return added;
  }

  // ---------- 退避 ----------

  /// 退避中の件数（テスト用）
  @visibleForTesting
  int get stagingCount => _stagers.length;

  /// preparing の行を前から順に、同時 stageParallel 件まで写し始める。
  /// 終わった所からまた埋めるので、同時に走るのはこの件数で頭打ちになる。
  void _pumpStage() {
    for (final t in _tasks) {
      if (_stagers.length >= stageParallel) return;
      if (t.status != TransferStatus.preparing) continue;
      if (_stagers.containsKey(t.id)) continue;
      final f = _stageOne(t);
      _stagers[t.id] = f;
      f.whenComplete(() {
        if (_stagers[t.id] == f) _stagers.remove(t.id);
        _changed();
        _pumpStage();
        _pump();
      });
    }
  }

  Future<void> _stageOne(TransferTask t) async {
    final src = t.sourcePath;
    final uri = t.sourceUri;
    final reader = t._reader;
    if (src == null && uri == null && reader == null) return;
    try {
      final dest = File('${(await _dir()).path}/up-${t.id}.bin');
      if (uri != null) {
        // content:// の権利は画面が生きている間だけ。積んだ直後の退避で直に写す
        await uriStager(uri, dest.path);
      } else if (src != null) {
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
        // content:// の権利は戻せないので、URI からの退避失敗は再選を促す文言にする（決めた事 10）
        t.error = t.sourceUri != null
            ? lostSourceMessage
            : 'ファイルを端末に退避できませんでした（${e is FileSystemException ? e.message : e}）';
      }
    }
    _persist(t);
  }

  // ---------- 実行 ----------

  /// その行が動いてよい接続か。積んだ時の接続と違う送り先へは送らない（#149）。
  /// 古い台帳の行は接続を持たないので、今の接続で動かす（切り替え前の従来通り）
  bool _forThisConn(TransferTask t) {
    final e = t.connEndpoint;
    if (e == null) return true;
    final cur = _connOf();
    return cur != null && isSameEndpoint(cur.endpoint, e);
  }

  void _pump() {
    if (_disposed || !_restored.isCompleted || !_configured()) return;
    for (final t in _tasks) {
      if (_workers.length >= parallel) break;
      if (t.status != TransferStatus.queued || _workers.containsKey(t.id)) continue;
      if (_waits.containsKey(t.id)) continue;
      if (!_forThisConn(t)) continue;
      if (!t.isUpload && !_canSaveOffline(t)) continue;
      // 回線と設定が合わない行は始めず待たせる。行ごとに見るので、
      // 片方の設定で待つ行があっても、もう片方の行は動く
      if (_wait(t) != null) continue;
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
      if (t.isUpload) await _albumAttach(t);
      // 台帳から外し終えてから完了にする。完了にした途端に転送中の通知（サービス）が外れ、
      // 画面を消された後なら残しておいたエンジンも畳まれる。書き終える前に畳まれると次の起動で送り直してしまう
      _completing.add(t);
      _changed();
      try {
        _persist(t);
        // 退避ファイルは完了を報告する前に消し終える。先に done にすると、完了を見た側
        // （画面・テスト）が掃除の途中の退避ファイルを見てしまう。
        // 消し終えて done になるまで _completing に残す。外すと別の行の書き込みが
        // 「転送中」で書き戻し、再起動で二重に上がる。
        // この間の操作は受け付けない（_operable で弾く）。サーバーが受け取った後なので完了を優先する
        await _dropStaged(t);
        t.status = TransferStatus.done;
        t.loaded = t.size;
      } finally {
        _completing.remove(t);
      }
      if (!_done.isClosed) _done.add(t);
    } catch (e) {
      if (token.isCancelled || !_owns(t, gen)) {
        // 止めた側（一時停止・取り消し）が状態を決めている
        _persist(t);
        return;
      }
      if (e is _ConnSwitched) {
        // 別の接続の行なので失敗にせず待機に戻す。元の接続へ戻った時に再開される
        t.status = TransferStatus.queued;
      } else if (_isNetwork(e)) {
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
      _persist(t);
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
    // 台帳から再開する行だけ、最初に台帳のキーを試す。それ以外は name → name (2) … の順
    var first = t.key;
    var n = 0;
    for (;;) {
      _checkCancelled(token);
      if (first == null && ++n > maxKeyAttempts) {
        throw const ApiError(409, '同じ名前のファイルが多すぎます');
      }
      final key = first ?? suffixedName(t.name, n);
      final resumed = first != null;
      first = null;
      try {
        await _place(t, token, size, key, resumed: resumed);
        return;
      } on ApiError catch (e) {
        if (e.status != 409 || token.isCancelled) rethrow;
        // 409 は分割の開始でも完了でも起きる。「同名がある」だけでは自分の物か分からんので、
        // 再開の時は中身を照合する。黙って完了にすると送れていないのに端末の退避まで消える
        if (resumed && await _storedSame(t, token, key, size)) {
          await _abortSession(t);
          t.key = key;
          _persist(t);
          return;
        }
        await _abortSession(t);
        t.key = null;
        t.loaded = 0;
        _persist(t);
      }
    }
  }

  /// 1つのキーへ送る。同名があれば 409 のまま投げ、呼び出し側が照合か名前の付け直しを決める。
  Future<void> _place(
      TransferTask t, CancelToken token, int size, String key,
      {required bool resumed}) async {
    if (size <= multipartThreshold) {
      final bytes = await _readAll(t);
      _checkCancelled(token);
      await api.putObject(t.lib, key, bytes, t.mime,
          cancelToken: token, sha256: t.sha256, onProgress: (s) {
        t.loaded = s;
        _progress();
      });
      t.key = key;
      _persist(t);
      return;
    }
    await sendMultipart(
      api: api,
      lib: t.lib,
      key: key,
      mime: t.mime,
      size: size,
      partSize: partSize,
      read: (offset, len) => _readChunk(t, offset, len),
      uploadId: resumed ? t.uploadId : null,
      parts: t.parts,
      cancelToken: token,
      abortStale: (_) async {
        await _abortSession(t);
        t.loaded = 0;
        _persist(t);
      },
      onCheckpoint: (id, parts) async {
        t.key = key;
        t.uploadId = id;
        t.parts = parts;
        if (parts.isEmpty) {
          _persist(t);
          return;
        }
        t.loaded = _confirmedBytes(t, size);
        _persist(t);
        _changed();
      },
      onProgress: (v) {
        if (v > t.loaded) t.loaded = v;
        _progress();
      },
    );
  }

  /// 開いたままの multipart を畳む。キーに紐づくので、名前を変える時は新しく作り直す必要がある。
  /// セッションは積んだ時の接続に開かれているので、切り替え後でも abort はそちらへ送る（#149）
  Future<void> _abortSession(TransferTask t) async {
    final id = t.uploadId;
    final key = t.key;
    t.uploadId = null;
    t.parts = [];
    if (id == null || key == null) return;
    try {
      final e = t.connEndpoint, tok = t.connToken;
      if (e != null && tok != null) {
        await api.multipartAbortOn(e, tok, t.lib, key, id);
      } else {
        await api.multipartAbort(t.lib, key, id);
      }
    } on ApiError catch (e) {
      debugPrint('stale multipart not aborted: $e');
    }
  }

  Future<bool> _storedSame(
      TransferTask t, CancelToken token, String key, int size) {
    Stream<List<int>> local() async* {
      for (var off = 0; off < size; off += partSize) {
        final len = off + partSize > size ? size - off : partSize;
        yield await _readChunk(t, off, len);
      }
    }

    // 照合の進捗は読んだバイト数で行に出す（#144）
    return api.storedMatches(t.lib, key, size, local,
        cancelToken: token, onProgress: (n) {
      t.loaded = n;
      _progress();
    });
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
      final thumb = await maker(File(path), t.mime).timeout(thumbTimeout);
      // 生成中に止められた・接続先が替わったなら、新しい送り先へは上げない
      if (t._token?.isCancelled == true) return;
      if (!_forThisConn(t)) return;
      if (thumb != null && thumb.isNotEmpty) await api.putThumb(t.lib, key, thumb);
    } catch (e) {
      debugPrint('upload thumb skipped: $e');
    }
  }

  /// 上げ終えた物を、選ばれたアルバムへ入れる（#102）。入れるキーはサーバーが
  /// 確定した名前（name (2) など改名後）。失敗しても物は保存済みなので、
  /// 完了は完了のまま「アルバムへの追加だけ失敗」として残す。追加前にアプリが
  /// 消された場合は台帳の albumAdded=false を見て次の起動で入れ直す。
  Future<void> _albumAttach(TransferTask t) async {
    final albumId = t.albumId, key = t.key;
    if (albumId == null || key == null || t.albumAdded) return;
    // 接続が替わっていたら別の送り先のアルバムへは入れない。待機に戻して元の接続でやり直す
    if (!_forThisConn(t)) throw _ConnSwitched();
    try {
      await api.albumAdd(t.lib, albumId, [key]);
      t.albumAdded = true;
      t.albumError = null;
    } on Exception catch (e) {
      debugPrint('album attach failed: $e');
      t.albumError = 'アルバムへの追加だけ失敗しました';
    }
  }

  Future<void> _download(TransferTask t, CancelToken token) async {
    void checkAccount() {
      if (!_canSaveOffline(t)) {
        throw const ApiError(403, '保存先アカウントの接続とロック解除を確認してください');
      }
    }
    checkAccount();
    final store = t.offlineAccountId == null
        ? offline : offline.forAccount(t.offlineAccountId!);
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
    checkAccount();
    if (bytes.isEmpty) throw const ApiError(0, 'empty download');
    // 取った先と今の接続が違うなら、新しい接続の袋へは書けない。
    // 待機へ戻して、元の接続へ戻した時にもう一度取り直す（#149）
    if (!_forThisConn(t)) throw const _ConnSwitched();
    t.size = bytes.length;
    // 原本を端末が読めず JPEG の写しが在る時は、写しを置く（HEIC を読めない環境向け）。
    // 読める原本・写しも読めない・写しの URL が無い時は原本を置く（今の動き）
    var plain = bytes;
    final canDecode = this.canDecode ?? canDecodeImageBytes;
    if (t.viewCopy && t.itemType != 'video' && !(await canDecode(bytes))) {
      final viewBytes = await _fetchViewCopy(t, token);
      if (viewBytes != null && viewBytes.isNotEmpty && await canDecode(viewBytes)) {
        plain = viewBytes;
      }
    }
    await store.saveBytes(
      lib: t.lib,
      key: t.itemKey!,
      type: t.itemType ?? 'image',
      name: t.name,
      plain: plain,
    );
  }

  /// JPEG の写しを取る。取れなければ null（原本を置く側へ戻る）
  Future<Uint8List?> _fetchViewCopy(TransferTask t, CancelToken token) async {
    Future<Uint8List> fetch(String u) => api.fetchBytes(u, cancelToken: token);
    final first = t.itemViewUrl ?? await api.itemViewUrl(t.lib, t.itemKey!);
    if (first == null) return null;
    try {
      return await fetch(first);
    } on ApiError catch (e) {
      // 署名URLの期限切れ。一覧から取り直して1回だけやり直す
      if (e.status != 403 || token.isCancelled) return null;
      final url = await api.itemViewUrl(t.lib, t.itemKey!);
      if (url == null) return null;
      try {
        return await fetch(url);
      } on ApiError {
        return null;
      }
    }
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
      // 削除が返らなくても完了の報告を止めない（止まるとサービスが残り続ける）
      await (() async {
        if (await f.exists()) await f.delete();
      })()
          .timeout(stagedDeleteTimeout);
    } on FileSystemException catch (e) {
      // 消し損ねても次の起動時の掃除で消える
      debugPrint('staged upload not removed: $e');
    } on TimeoutException {
      // 残ったファイルは次の起動時の掃除に任せる
      debugPrint('staged upload delete timed out: $p');
    }
  }

  // ---------- 操作 ----------

  /// 接続資格を替える前にダウンロードだけ止める。保存済みデータとアップロードは触らない。
  void pauseOfflineDownloads() {
    for (final t in _tasks.toList()) {
      if (!t.isUpload && t.active) pause(t.id);
    }
  }

  /// 一時停止。退避したファイル・uploadId・確定済みパートは残し、再開で続きから送る。
  void pause(String id) {
    final t = _operable(id);
    if (t == null || !t.active) return;
    t._gen++;
    t.status = TransferStatus.paused;
    _waits.remove(id)?.cancel();
    t._token?.cancel('paused');
    _persist(t);
    _changed();
    _pump();
  }

  void resume(String id) {
    final t = _operable(id);
    if (t == null || t.status != TransferStatus.paused) return;
    t._gen++;
    _requeue(t);
  }

  /// 失敗・取り消しの行をやり直す。
  void retry(String id) {
    final t = _operable(id);
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

  /// 接続先の切り替えなどで、まだ送る可能性のある行を全部止める。
  /// 失敗の行も接続のたびに自動で積み直されるので一緒に止める。
  /// 行と退避したファイルは残すので、同じ送り先へ戻れば再開で続きから送れる
  void pauseUnsent() {
    final touched = <TransferTask>[];
    for (final t in _tasks.toList()) {
      if (t.active) {
        pause(t.id);
        touched.add(t);
      } else if (t.status == TransferStatus.error) {
        t.status = TransferStatus.paused;
        _waits.remove(t.id)?.cancel();
        touched.add(t);
      }
    }
    if (touched.isNotEmpty) {
      _persistRows(touched);
      _changed();
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
      _pumpStage();
    } else {
      t.status = TransferStatus.queued;
    }
    _persist(t);
    _changed();
    _pump();
  }

  /// 取り消し。動いている処理が止まるのを待ってから、退避ファイルと multipart を片付けて行を消す。
  Future<void> cancel(String id) async {
    final t = _operable(id);
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
    t._gone = true;
    await _persist(t);
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
    final t = _operable(id);
    if (t == null ||
        (t.status != TransferStatus.done &&
            t.status != TransferStatus.cancelled)) {
      return;
    }
    _tasks.remove(t);
    t._gone = true;
    _persist(t);
    _changed();
  }

  /// 終わった行（完了・取り消し）をまとめて消す。失敗の行とその退避ファイルは残す。
  Future<void> clearFinished() async {
    bool removable(TransferTask t) =>
        (t.status == TransferStatus.done ||
            t.status == TransferStatus.cancelled) &&
        !_completing.contains(t);
    final gone = _tasks.where(removable).toList();
    _tasks.removeWhere(removable);
    _changed();
    for (final t in gone) {
      t._gone = true;
      await _cleanup(t);
    }
    await _persistRows(gone);
  }

  /// 止まっている待ちを解いて流し直す（アプリへの復帰・接続の後）。
  void wake() {
    for (final w in _waits.values) {
      w.cancel();
    }
    _waits.clear();
    _pump();
  }

  /// アップロードは送信、オフライン保存はダウンロードの設定で見る
  NetWait? _wait(TransferTask t) => transferWait(
      net, policy, t.isUpload ? TransferLeg.upload : TransferLeg.download,
      foreground: foreground);

  /// 一覧の文言用。待機の行が、今の回線と設定のどれで待っているか。待っていなければ null
  NetWait? waitOf(String id) {
    final t = _find(id);
    if (t == null || t.status != TransferStatus.queued) return null;
    return _wait(t);
  }

  /// 設定か省データで待っている行の数。サービスの通知に出す。
  /// オフラインで待つ行は数えない（今まで通り「転送中」のまま回線の戻りを待つ）
  int get waitingCount => _tasks
      .where((t) =>
          t.status == TransferStatus.queued &&
          _forThisConn(t) &&
          (t.isUpload || _canSaveOffline(t)) &&
          (_wait(t) == NetWait.wifi || _wait(t) == NetWait.dataSaver))
      .length;

  /// 回線の知らせ。オンラインに戻った時は待ちを解いて流し直す
  void setNetwork(NetState s) {
    if (net == s) return;
    final wasOnline = net.online;
    net = s;
    _applyNet(recovered: !wasOnline && s.online);
  }

  /// 旧来の「使えるか」だけの知らせ。回線の種類は変えず、使えるかだけを替える
  void setOnline(bool value) {
    if (online == value) return;
    setNetwork(value ? NetState.unknownOnline : NetState.offline);
  }

  void setPolicy(TransferNetPolicy p) {
    if (policy == p) return;
    policy = p;
    _applyNet();
  }

  void setForeground(bool v) {
    if (foreground == v) return;
    foreground = v;
    _applyNet();
  }

  void _applyNet({bool recovered = false}) {
    for (final t in _tasks.toList()) {
      if (t.status == TransferStatus.running && _stopsForNet(_wait(t))) {
        _stopForNetwork(t);
      }
    }
    // 設定をオフにした時は待っていた行がすぐ始まる
    if (recovered) {
      wake();
    } else {
      _pump();
    }
    _changed();
  }

  /// 動いている行を止める理由か。オフラインは含めない。通信が切れれば失敗として返り、
  /// 既存の回復（待機に戻して回線の復帰で再開）に任せる。ここで取り消すと、
  /// 一瞬の圏外で送信中の行が毎回やり直しになる
  bool _stopsForNet(NetWait? w) => w == NetWait.wifi || w == NetWait.dataSaver;

  /// 走っている行を、取り消しの仕組みで止めて待機に戻す。
  /// 一時停止と同じく世代を進めて古い実行が状態を書き換えないようにし、
  /// 退避ファイル・uploadId・確定したパートは残す（失敗や取り消しにはしない）
  void _stopForNetwork(TransferTask t) {
    t._gen++;
    t.status = TransferStatus.queued;
    _waits.remove(t.id)?.cancel();
    t._token?.cancel('network');
    _persist(t);
  }

  /// 動いているものが片付くまで待つ（テスト用）。
  Future<void> idle() async {
    while (_workers.isNotEmpty || _stagers.isNotEmpty) {
      await Future.wait([..._workers.values, ..._stagers.values]);
    }
    await _ledgerLoop;
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
