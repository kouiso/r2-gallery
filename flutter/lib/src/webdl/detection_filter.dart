import 'package:flutter/foundation.dart';

import 'detected.dart';

/// 検出一覧から「取り込み対象にしない」候補をURL単位で記録する（#37/#38）。
///
/// 保持は今開いているページの間だけ。別ページへ移動したりブラウザを閉じたら
/// `reset` で捨てる — 全サイト共通の恒久ブラックリストは本件の要求ではないため。
/// 一覧が再検知で差し替わってもここは残るので、同じURLの再検出で除外が戻らない。
class DetectionFilter extends ChangeNotifier {
  /// 取り込み対象から外した候補の URL
  final excluded = <String>{};

  /// 除外操作の対象に選んだ候補の URL
  final selected = <String>{};

  /// 除外されていない候補だけを返す
  List<DetectedItem> visibleOf(List<DetectedItem> items) =>
      [for (final d in items) if (!excluded.contains(d.url)) d];

  /// 除外された候補だけを返す（戻す操作の一覧用）
  List<DetectedItem> excludedOf(List<DetectedItem> items) =>
      [for (final d in items) if (excluded.contains(d.url)) d];

  void toggle(String url) {
    if (!selected.remove(url)) selected.add(url);
    notifyListeners();
  }

  /// 選んだ候補を取り込み対象から外す。除外は選択を解いて終わる
  void excludeSelected() {
    if (selected.isEmpty) return;
    excluded.addAll(selected);
    selected.clear();
    notifyListeners();
  }

  /// 今見えている画像をまとめて外す。動画・音声・種類不明は対象にしない
  void excludeImages(List<DetectedItem> items) {
    var changed = false;
    for (final d in items) {
      if (d.kind == DetectedKind.image && !excluded.contains(d.url)) {
        excluded.add(d.url);
        changed = true;
      }
    }
    if (changed) {
      selected.removeAll(excluded);
      notifyListeners();
    }
  }

  /// 誤って外した候補を対象へ戻す
  void restore(String url) {
    if (excluded.remove(url)) notifyListeners();
  }

  /// ページ移動・ブラウザ終了でリセットする
  void reset() {
    if (excluded.isEmpty && selected.isEmpty) return;
    excluded.clear();
    selected.clear();
    notifyListeners();
  }
}
