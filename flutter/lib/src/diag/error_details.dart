import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/models.dart';
import '../store/kv.dart';

/// 失敗の詳しい理由を画面に出すかの切り替え（#237）。
///
/// 画面の決まった文だけではスクショから原因を追えないため、設定で ON にした時だけ
/// 理由（HTTP の番号・Worker の返した理由・どの呼び出しか・例外の種類）を文の下に足す。
/// 呼び出し元が AppState を持たない画面も多いので、アプリ全体で 1 つの値として持つ。
class ErrorDetails {
  ErrorDetails._();

  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static bool get on => enabled.value;

  static Future<void> load() async {
    try {
      enabled.value = (await Kv.get(Keys.errorDetails)) == '1';
    } on Object catch (e) {
      // 読めなくても既定の OFF のまま動かす。起動を止める理由にはしない
      debugPrint('error details setting load failed: $e');
    }
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    await Kv.set(Keys.errorDetails, value ? '1' : '0');
  }

  /// 決まった文 [base] に、ON の時だけ [error] の詳しい理由を足す。
  static String compose(String base, Object? error) {
    if (!on || error == null) return base;
    return '$base\n\n${describeErrorDetail(error)}';
  }

  /// 画面に出す失敗の文。ON の時は詳しい理由、OFF の時は今まで通り toString()。
  static String text(Object error) =>
      on ? describeErrorDetail(error) : error.toString();
}

/// スクショから原因を追える形の詳しい理由。トークンらしき並びは伏せ、長すぎる時は切る。
String describeErrorDetail(Object e) {
  final lines = <String>[];
  if (e is ApiError) {
    lines.add(e.status > 0 ? 'HTTP ${e.status}' : '通信エラー（応答なし）');
    if (e.code != null) lines.add('理由: ${e.code}');
    if (e.request != null) lines.add('呼び出し: ${e.request}');
    if (e.kind != null) lines.add('種類: ${e.kind}');
    lines.add('内容: ${e.message}');
  } else if (e is DioException) {
    final o = e.requestOptions;
    final status = e.response?.statusCode;
    lines.add(status != null ? 'HTTP $status' : '通信エラー（応答なし）');
    lines.add('呼び出し: ${o.method} ${o.uri.path}');
    lines.add('種類: ${e.type.name}');
    if (e.message != null) lines.add('内容: ${e.message}');
  } else if (e is String) {
    // 再生器などが理由を文字列でだけ返す場合
    lines.add('内容: $e');
  } else {
    lines.add('種類: ${e.runtimeType}');
    lines.add('内容: $e');
  }
  return maskSecrets(lines.join('\n'), max: 600);
}

/// トークンらしき並びを伏せる。画面のスクショは人に渡すので、鍵は決して出さない。
String maskSecrets(String s, {int max = 600}) {
  var msg = s
      .replaceAll(RegExp(r'Bearer\s+\S+'), 'Bearer ***')
      .replaceAllMapped(
          RegExp(r'([?&](?:token|s|sig|signature)=)[^&\s]+',
              caseSensitive: false),
          (m) => '${m[1]}***');
  if (msg.trim().isEmpty) msg = '不明なエラー';
  return msg.length > max ? '${msg.substring(0, max)}…' : msg;
}
