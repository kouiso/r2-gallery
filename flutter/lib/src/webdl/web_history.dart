import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../store/kv.dart';

/// 取り込みが済んだファイルの記録（取り込み画面の「ダウンロード履歴」）。
class WebHistoryEntry {
  final String name;
  final String key;
  final String url;
  final String mime;
  final int size;
  final int at;

  /// 取り込んだ先のライブラリ。この項目を足す前の記録には無いので空になる。
  final String lib;
  const WebHistoryEntry({
    required this.name,
    required this.key,
    required this.url,
    required this.mime,
    required this.size,
    required this.at,
    this.lib = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'key': key,
        'url': url,
        'mime': mime,
        'size': size,
        'at': at,
        if (lib.isNotEmpty) 'lib': lib,
      };

  factory WebHistoryEntry.fromJson(Map<String, dynamic> j) => WebHistoryEntry(
        name: (j['name'] as String?) ?? '',
        key: (j['key'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        mime: (j['mime'] as String?) ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        at: (j['at'] as num?)?.toInt() ?? 0,
        lib: (j['lib'] as String?) ?? '',
      );
}

/// 履歴の保存先。既定は端末の KV で、テストでは読み書きを差し替える。
class WebHistoryStore {
  WebHistoryStore({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
  })  : _read = read ?? (() => Kv.get(Keys.webHistory)),
        _write = write ?? ((v) => Kv.set(Keys.webHistory, v));

  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;

  /// 並行して終わった取り込みが読み書きを重ねて記録を取りこぼさんよう、書き込みは1本ずつにする
  Future<void> _tail = Future.value();

  static const maxEntries = 200;

  Future<void> add(WebHistoryEntry e) {
    final next = _tail.then((_) async {
      final list = await _load();
      list.add(e);
      final kept =
          list.length > maxEntries ? list.sublist(list.length - maxEntries) : list;
      await _write(jsonEncode([for (final x in kept) x.toJson()]));
    });
    // 1件の失敗で後続の記録が止まらんようにする。失敗そのものは next で呼び出し側へ返る
    _tail = next.then((_) {}, onError: (Object e) {
      debugPrint('web history write failed: $e');
    });
    return next;
  }

  /// 新しい順。壊れた保存値は空として扱う。
  Future<List<WebHistoryEntry>> list() async {
    await _tail;
    return (await _load()).reversed.toList();
  }

  Future<List<WebHistoryEntry>> _load() async {
    try {
      final raw = await _read();
      if (raw == null || raw.isEmpty) return [];
      return [
        for (final e in jsonDecode(raw) as List)
          WebHistoryEntry.fromJson(e as Map<String, dynamic>),
      ];
    } on FormatException {
      return [];
    } on TypeError {
      return [];
    }
  }
}
