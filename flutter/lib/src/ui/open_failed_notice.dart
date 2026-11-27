import 'package:flutter/material.dart';

/// 開く時の引き直しが null を返した時の通知。
/// null は「その間に消えていた」と「引き直しの通信が失敗した」を分けないので、
/// どちらにも当てはまる文言にする（片方だけを言うと、もう片方の時に嘘になる）。
/// 写真タブ・フォルダ・アルバムで同じ文言にそろえ、無反応にしないために共通にしている。
void showOpenFailedNotice(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('開けませんでした。消えたか、通信の不調かもしれません。もう一度お試しください')));
}
