import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../store/kv.dart';
import '../store/private_storage.dart';

typedef _DecryptInput = ({Uint8List raw, List<int> key});
const _backgroundDecryptBytes = 256 * 1024;

Future<Uint8List?> _decryptOffline(_DecryptInput input) async {
  final raw = input.raw;
  try {
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        Uint8List.sublistView(raw, 12, raw.length - 16),
        nonce: Uint8List.sublistView(raw, 0, 12),
        mac: Mac(Uint8List.sublistView(raw, raw.length - 16)),
      ),
      secretKey: SecretKey(input.key),
    );
    return plain is Uint8List ? plain : Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    return null;
  }
}

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
    if (file is! String ||
        !RegExp(r'^[a-f0-9]{64}\.bin$').hasMatch(file) ||
        mime is! String || name is! String) {
      return null;
    }
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
  final String? accountId;
  const OfflineRef(this.lib, this.key, this.entry, {this.accountId});
}

class _OfflineBackend {
  _OfflineBackend(this.kv, this.dir, this.enabled);
  final SecretKv kv;
  final Future<Directory> Function() dir;
  final bool enabled;
  final Map<String, OfflineStore> accounts = {};
  Future<List<int>>? key;
}

/// 端末に暗号化して置くオフライン保存。KMP 版 OfflineStore と同じ作り:
/// 中身は AES-256-GCM（先頭12バイトが IV、続いて暗号文と16バイトのタグ）でアプリ専用領域に置き、
/// 鍵（DEK）と目録は端末の秘密置き場に持つ。接続のトークンはここには一切置かない。
class OfflineStore extends ChangeNotifier {
  OfflineStore({SecretKv? kv, Future<Directory> Function()? dir,
      @visibleForTesting bool forceUnsupported = false})
      : _backend = _OfflineBackend(kv ?? const KvSecretKv(), dir ?? _defaultDir,
            supported && !forceUnsupported),
        accountId = null;

  OfflineStore._(this._backend, this.accountId);

  static const dekKey = 'r2g.offline.dek';
  static const manifestKey = 'r2g.offline.manifest';

  /// 暗号化できる環境か。Web は端末内のファイル置き場が無いので操作ごと隠す（KMP 版と同じ扱い）。
  static bool get supported => !kIsWeb;

  void _requireSupported() {
    if (!_backend.enabled) throw UnsupportedError('この環境はアプリ専用保存に対応していません');
  }

  final _OfflineBackend _backend;
  final String? accountId;
  SecretKv get _kv => _backend.kv;
  String get _manifestKey => accountId == null
      ? manifestKey
      : '$manifestKey.account.${hash.sha256.convert(utf8.encode(accountId!))}';
  final _aes = AesGcm.with256bits();
  final _rand = Random.secure();

  Map<String, OfflineEntry>? _manifest;
  Directory? _dir;
  // 目録の読み書きを1本に並べる。並行で書くと後から書いた方が前の追加を消してしまう
  Future<void>? _lock;

  static Future<Directory> _defaultDir() => privatePersistentDirectory('offline');

  /// 接続先・資格情報に結び付く不変の保存先。古い転送も別アカウントの保存先には変わらない。
  OfflineStore forAccount(String id) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
    if (accountId == id) return this;
    return _backend.accounts.putIfAbsent(id, () => OfflineStore._(_backend, id));
  }

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

  static String fileNameFor(String entry) =>
      '${hash.sha256.convert(utf8.encode(entry))}.bin';

  Future<Directory> _files() async {
    _requireSupported();
    final d = _dir ??= await _backend.dir();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<List<int>> _key() async {
    _requireSupported();
    final pending = _backend.key ??= _readKey();
    try {
      return await pending;
    } catch (_) {
      // 一時的な秘密置き場の失敗は再試行可能にし、後続の取得は消さない。
      if (identical(_backend.key, pending)) _backend.key = null;
      rethrow;
    }
  }

  Future<List<int>> _readKey() async {
    final stored = await _kv.get(dekKey);
    if (stored != null) return base64Decode(stored);
    final fresh = List<int>.generate(32, (_) => _rand.nextInt(256));
    await _kv.set(dekKey, base64Encode(fresh));
    return fresh;
  }

  Future<Map<String, OfflineEntry>> _load() async {
    _requireSupported();
    final cached = _manifest;
    if (cached != null) return cached;
    final m = <String, OfflineEntry>{};
    final raw = await _kv.get(_manifestKey);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final e = OfflineEntry.fromJson(v);
            if (k is String && e != null) m[k] = e;
          });
        }
      } on FormatException {
        // 壊れた目録で全部を失うより、空から始めて保存し直せる方を取る
        debugPrint('offline manifest unreadable');
      }
    }
    return _manifest = m;
  }

  Future<void> _write(Map<String, OfflineEntry> m) async {
    await _kv.set(_manifestKey,
        jsonEncode({for (final e in m.entries) e.key: e.value.toJson()}));
    _manifest = m;
  }

  /// 平文を暗号化して保存する。同じ項目を保存し直したら上書きする。
  Future<void> saveBytes({
    required String lib,
    required String key,
    required String type,
    required String name,
    required Uint8List plain,
  }) async {
    _requireSupported();
    final iv = List<int>.generate(12, (_) => _rand.nextInt(256));
    final box = await _aes.encrypt(plain,
        secretKey: SecretKey(await _key()), nonce: iv);
    final ek = entryKey(lib, key);
    final file = fileNameFor(accountId == null ? ek : '$accountId\u0000$ek');
    final out = BytesBuilder(copy: false)
      ..add(iv)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    await File('${(await _files()).path}/$file')
        .writeAsBytes(out.takeBytes(), flush: true);
    await _serial(() async {
      final m = Map.of(await _load());
      m[ek] = OfflineEntry(
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
      (await _load()).containsKey(entryKey(lib, key));

  /// 画面から同期で引く用。目録を読む前は false。
  bool hasCached(String lib, String key) =>
      _manifest?.containsKey(entryKey(lib, key)) ?? false;

  Future<int> count() async => (await _load()).length;

  Future<int> totalBytes() async => (await _load()).values.fold<int>(
      0, (total, entry) => total + entry.size);

  /// 所有者の分からない旧保存は、自動で現在の接続へ関連付けたり消したりしない。
  Future<bool> hasLegacyData() async {
    _requireSupported();
    final raw = await _kv.get(manifestKey);
    if (raw == null || raw.trim().isEmpty) return false;
    try {
      final legacy = jsonDecode(raw);
      return legacy is Map && legacy.isNotEmpty;
    } on FormatException {
      return true;
    }
  }

  Future<List<OfflineRef>> list() async {
    final m = await _load();
    final out = <OfflineRef>[];
    for (final e in m.entries) {
      final i = e.key.indexOf('\u0000');
      out.add(i < 0
          ? OfflineRef('', e.key, e.value, accountId: accountId)
          : OfflineRef(e.key.substring(0, i), e.key.substring(i + 1), e.value,
              accountId: accountId));
    }
    out.sort((a, b) => b.entry.savedAt.compareTo(a.entry.savedAt));
    return out;
  }

  /// 復号してメモリに返す。壊れていたり鍵が合わなければ null。
  Future<Uint8List?> readBytes(String lib, String key) async {
    final entry = (await _load())[entryKey(lib, key)];
    if (entry == null) return null;
    try {
      final raw = await File('${(await _files()).path}/${entry.file}').readAsBytes();
      if (raw.length < 12 + 16) return null;
      final input = (raw: raw, key: await _key());
      // 全体のGCM認証は省かず、大きい復号がUIのスピナーや操作を止めるのだけを避ける。
      // 別isolateへ渡すのはバイト列と鍵だけ。Keychainやplatform channelはUI側で扱う。
      final plain = raw.length - 28 >= _backgroundDecryptBytes
          ? await compute(_decryptOffline, input, debugLabel: 'offline-decrypt')
          : await _decryptOffline(input);
      if (plain == null) debugPrint('offline blob rejected');
      return plain;
    } on FileSystemException {
      debugPrint('offline blob unreadable');
      return null;
    }
  }

  Future<void> remove(String lib, String key) async {
    final gone = await _serial(() async {
      final m = Map.of(await _load());
      final e = m.remove(entryKey(lib, key));
      if (e != null) await _write(m);
      return e;
    });
    if (gone == null) return;
    notifyListeners();
    await _deleteBlob(gone.file);
  }

  /// すべて削除。サーバー上の写真・動画には触れない。
  Future<void> clear() async {
    final files = await _serial(() async {
      final m = await _load();
      final names = m.values.map((e) => e.file).toList();
      await _write({});
      return names;
    });
    notifyListeners();
    for (final f in files) {
      await _deleteBlob(f);
    }
  }

  Future<void> _deleteBlob(String name) async {
    try {
      final f = File('${(await _files()).path}/$name');
      if (await f.exists()) await f.delete();
    } on Exception {
      // 目録からは外れているので、残った暗号文は鍵が無いと読めないゴミになるだけ
      debugPrint('offline blob not removed');
    }
  }
}
