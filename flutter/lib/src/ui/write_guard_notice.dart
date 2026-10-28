import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/write_guard.dart';

/// 書き込みの入口で呼ぶ。書けない時は理由をスナックバーで出して false を返す。
/// 黙って何もしないと、押したのに反応が無いように見えるため。
bool ensureWritable(
  BuildContext context,
  AppState app,
  String? lib,
  WriteAction action,
) {
  final msg = app.writeBlock(lib, action);
  if (msg == null) return true;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(msg)));
  return false;
}
