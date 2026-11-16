import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../store/kv.dart';

/// 端末の秘密置き場（Keystore/Keychain）への読み書き。テストで差し替える。
abstract class SecretKv {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
}

class KvSecretKv implements SecretKv {
  const KvSecretKv();
  @override
  Future<String?> get(String key) => Kv.get(key);
  @override
  Future<void> set(String key, String value) => Kv.set(key, value);
}

/// オフライン保存の1件。KMP 版 OfflineEntry と同じ項目。
class OfflineEntry {
  final String file;
  final String mime;
  final String name;
  final int size;
  final int savedAt;
  const OfflineEntry({
    required this.file,
    required this.mime,
    required this.name,
    required this.size,
    required this.savedAt,
  });

  bool get isVideo => mime.startsWith('video/');

  Map<String, Object> toJson() =>
      {'file': file, 'mime': mime, 'name': name, 'size': size, 'savedAt': savedAt};

  static OfflineEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final file = j['file'], mime = j['mime'], name = j['name'];
    final size = j['size'], at = j['savedAt'];
    if (file is! String || mime is! String || name is! String) return null;
    return OfflineEntry(
      file: file,
      mime: mime,
      name: name,
      size: size is num ? size.toInt() : 0,
      savedAt: at is num ? at.toInt() : 0,
    );
  }
}

/// 一覧に出す1件（どのライブラリのどのキーか）。
class OfflineRef {
  final String lib;
  final String key;
  final OfflineEntry entry;
  const OfflineRef(this.lib, this.key, this.entry);
}

/// 端末に暗号化して置くオフライン保存。KMP 版 OfflineStore と同じ作り:
/// 中身は AES-256-GCM（先頭12バイトが IV、続いて暗号文と16バイトのタグ）でアプリ専用領域に置き、
/// 鍵（DEK）と目録は端末の秘密置き場に持つ。接続のトークンはここには一切置かない。
///
/// 目録は接続先ごとに分ける。分けないと、別の接続先に同じキーの写真がある時に
/// 前の接続先で保存した中身を「保存済み」として出してしまう（#149）。
/// ListingCache の ListingScope と同じ考え方で、ローカル状態の帰属は1つの決まりに揃える。
class OfflineStore extends ChangeNotifier {
  OfflineStore(
      {SecretKv? kv,
      Future<Directory> Function()? dir,
      String? Function()? endpoint})
      : _kv = kv ?? const KvSecretKv(),
        _dirFn = dir ?? _defaultDir,
        _endpoint = endpoint ?? (() => null);

  static const dekKey = 'r2g.offline.dek';
  static const manifestKey = 'r2g.offline.manifest';

  /// 暗号化できる環境か。Web は端末内のファイル置き場が無いので操作ごと隠す（KMP 版と同じ扱い）。
  static bool get supported => !kIsWeb;

  final SecretKv _kv;
  final Future<Directory> Function() _dirFn;

  /// いま繋がっている接続先。目録・実ファイルの名付けにだけ使い、値そのものは書かない
  final String? Function() _endpoint;
  final _aes = AesGcm.with256bits();
  final _rand = Random.secure();

  /// 目録。外側のキーは接続先のハッシュ（未接続の物は ''）、内側は lib\0key。
  Map<String, Map<String, OfflineEntry>>? _manifest;
  List<int>? _dek;
  Directory? _dir;
  // 目録の読み書きを1本に並べる。並行で書くと後から書いた方が前の追加を消してしまう
  Future<void>? _lock;

  static Future<Directory> _defaultDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/offline');

  Future<T> _serial<T>(Future<T> Function() body) async {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future;
    try {
      if (prev != null) await prev;
      return await body();
    } finally {
      done.complete();
    }
  }

  /// 同じキーが別ライブラリにもあり得るので、ライブラリ込みで区別する（KMP 版と同じ）
  static String entryKey(String lib, String key) =>
      lib.isEmpty ? key : '$lib\u0000$key';

  /// 目録の外側のキー。接続先そのものは書かず、ListingScope と同じくハッシュだけ残す
  String _scopeId() {
    final e = _endpoint();
    if (e == null || e.isEmpty) return '';
    return hash.sha256.convert(utf8.encode(e)).toString();
  }

  /// 実ファイルの名付けには接続先も混ぜる。同じキーの別の中身が上書きし合わんように（#149）
  static String fileNameFor(String scopedEntry) =>
      '${hash.sha256.convert(utf8.encode(scopedEntry))}.bin';

  Future<Directory> _files() async {
    final d = _dir ??= await _dirFn();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<int>> _key() async {
    final cached = _dek;
    if (cached != null) return cached;
    final stored = await _kv.get(dekKey);
    if (stored != null) return _dek = base64Decode(stored);
    final fresh = List<int>.generate(32, (_) => _rand.nextInt(256));
    await _kv.set(dekKey, base64Encode(fresh));
    return _dek = fresh;
  }

  /// 目録の形。v2 は接続先ごとの袋、v1（接続先なしの平たい形）は未接続の袋として読む。
  /// 繋がっている接続がある時は、v1 の分をその接続先の袋に移す（#149 の読み替え）。
  /// 何度読み直しても同じ結果になるので、途中で落ちても安全。
  Future<Map<String, Map<String, OfflineEntry>>> _load() async {
    final cached = _manifest;
    if (cached != null) return cached;
    var m = <String, Map<String, OfflineEntry>>{};
    final raw = await _kv.get(manifestKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['scopes'] is Map) {
          (decoded['scopes'] as Map).forEach((scope, entries) {
            if (scope is! String || entries is! Map) return;
            final inner = <String, OfflineEntry>{};
            entries.forEach((k, v) {
              final e = OfflineEntry.fromJson(v);
              if (k is String && e != null) inner[k] = e;
            });
            if (inner.isNotEmpty) m[scope] = inner;
          });
        } else if (decoded is Map) {
          final legacy = <String, OfflineEntry>{};
          decoded.forEach((k, v) {
            final e = OfflineEntry.fromJson(v);
            if (k is String && e != null) legacy[k] = e;
          });
          if (legacy.isNotEmpty) m[''] = legacy;
        }
      } on FormatException catch (e) {
        // 壊れた目録で全部を失うより、空から始めて保存し直せる方を取る
        debugPrint('offline manifest unreadable: $e');
      }
    }
    final scope = _scopeId();
    final legacy = m[''];
    if (scope.isNotEmpty && legacy != null && legacy.isNotEmpty) {
      m.remove('');
      m.putIfAbsent(scope, () => {}).addAll(legacy);
      await _kv.set(manifestKey, _encode(m));
    }
    return _manifest = m;
  }

  String _encode(Map<String, Map<String, OfflineEntry>> m) => jsonEncode({
        'v': 2,
        'scopes': {
          for (final s in m.entries)
            if (s.value.isNotEmpty)
              s.key: {for (final e in s.value.entries) e.key: e.value.toJson()},
        },
      });

  /// 今の接続先の袋。無ければ作る
  Map<String, OfflineEntry> _cur(Map<String, Map<String, OfflineEntry>> m) =>
      m.putIfAbsent(_scopeId(), () => {});

  Future<void> _write(Map<String, Map<String, OfflineEntry>> m) async {
    _manifest = m;
    await _kv.set(manifestKey, _encode(m));
  }

  /// 平文を暗号化して保存する。同じ項目を保存し直したら上書きする。
  Future<void> saveBytes({
    required String lib,
    required String key,
    required String type,
    required String name,
    required Uint8List plain,
  }) async {
    final iv = List<int>.generate(12, (_) => _rand.nextInt(256));
    final box = await _aes.encrypt(plain,
        secretKey: SecretKey(await _key()), nonce: iv);
    final ek = entryKey(lib, key);
    final file = fileNameFor('${_scopeId()}\u0000$ek');
    final out = BytesBuilder(copy: false)
      ..add(iv)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    await File('${(await _files()).path}/$file')
        .writeAsBytes(out.takeBytes(), flush: true);
    await _serial(() async {
      final m = Map.of(await _load());
      _cur(m)[ek] = OfflineEntry(
        file: file,
        mime: type == 'video' ? 'video/mp4' : 'image/*',
        name: name,
        size: plain.length,
        savedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _write(m);
    });
    notifyListeners();
  }

  Future<bool> has(String lib, String key) async =>
      _cur(await _load()).containsKey(entryKey(lib, key));

  /// 画面から同期で引く用。目録を読む前は false。
  bool hasCached(String lib, String key) =>
      _manifest?[_scopeId()]?.containsKey(entryKey(lib, key)) ?? false;

  Future<int> count() async => _cur(await _load()).length;

  Future<List<OfflineRef>> list() async {
    final m = _cur(await _load());
    final out = <OfflineRef>[];
    for (final e in m.entries) {
      final i = e.key.indexOf('\u0000');
      out.add(i < 0
          ? OfflineRef('', e.key, e.value)
          : OfflineRef(e.key.substring(0, i), e.key.substring(i + 1), e.value));
    }
    out.sort((a, b) => b.entry.savedAt.compareTo(a.entry.savedAt));
    return out;
  }

  /// 復号してメモリに返す。壊れていたり鍵が合わなければ null。
  Future<Uint8List?> readBytes(String lib, String key) async {
    final entry = _cur(await _load())[entryKey(lib, key)];
    if (entry == null) return null;
    try {
      final raw = await File('${(await _files()).path}/${entry.file}').readAsBytes();
      if (raw.length < 12 + 16) return null;
      final plain = await _aes.decrypt(
        SecretBox(
          Uint8List.sublistView(raw, 12, raw.length - 16),
          nonce: Uint8List.sublistView(raw, 0, 12),
          mac: Mac(Uint8List.sublistView(raw, raw.length - 16)),
        ),
        secretKey: SecretKey(await _key()),
      );
      return plain is Uint8List ? plain : Uint8List.fromList(plain);
    } on FileSystemException catch (e) {
      debugPrint('offline blob unreadable: $e');
      return null;
    } on SecretBoxAuthenticationError catch (e) {
      debugPrint('offline blob rejected: $e');
      return null;
    }
  }

  Future<void> remove(String lib, String key) async {
    final gone = await _serial(() async {
      final m = Map.of(await _load());
      final e = _cur(m).remove(entryKey(lib, key));
      if (e != null) await _write(m);
      return e;
    });
    if (gone == null) return;
    await _deleteBlob(gone.file);
    notifyListeners();
  }

  /// すべて削除。サーバー上の写真・動画には触れない。
  /// 端末の空きを返す操作なので、ほかの接続先の分も一緒に消す
  Future<void> clear() async {
    final files = await _serial(() async {
      final m = await _load();
      final names = [
        for (final entries in m.values)
          for (final e in entries.values) e.file,
      ];
      await _write({});
      return names;
    });
    for (final f in files) {
      await _deleteBlob(f);
    }
    notifyListeners();
  }

  Future<void> _deleteBlob(String name) async {
    try {
      final f = File('${(await _files()).path}/$name');
      if (await f.exists()) await f.delete();
    } on Exception catch (e) {
      // 目録からは外れているので、残った暗号文は鍵が無いと読めないゴミになるだけ
      debugPrint('offline blob not removed: $e');
    }
  }
}
