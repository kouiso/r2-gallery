import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'sort_mode.dart';

/// 選択バーの1操作。アイコンの下に必ず文字を付ける（KMP 版 SelAction と同じ）。
/// [onTap] が null の時は押せない表示にする（処理中など）。
class SelAction {
  final String label;
  final IconData icon;
  final bool danger;
  final VoidCallback? onTap;
  const SelAction(this.label, this.icon, {this.danger = false, this.onTap});
}

/// 選択中の一覧が上下のバーへ見せる面。シェルや画面はこれだけ見て見出しと操作を描く。
abstract class SelectionSurface implements Listenable {
  int get selectedCount;
  bool get allSelected;
  void toggleAll();
  void clearSelection();

  /// 選択バーに並べる操作。読み取り専用や未実装の操作はここで外す。
  List<SelAction> selectionActions(BuildContext context);
}

/// 写真タブとシェル（上のアプリバー・下のタブ）の橋渡し。
/// 並び順はライブラリを切り替えても保つ（KMP 版も画面の状態として持ち越していた）。
class PhotosChrome extends ChangeNotifier {
  SortMode _sort = SortMode.dateNew;
  SortMode get sort => _sort;
  set sort(SortMode m) {
    if (m == _sort) return;
    _sort = m;
    notifyListeners();
  }

  SelectionSurface? _surface;
  SelectionSurface? get surface => _surface;
  bool get selecting => (_surface?.selectedCount ?? 0) > 0;

  // 一覧の作り直し中（build の最中）に選択が変わると、上にあるシェルへの通知が
  // 「build 中の markNeedsBuild」になる。その時だけ描画後へ回す
  void _forward() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }

  /// 写真タブが生まれた時に面を登録する。登録は build の最中なので、ここでは通知しない。
  void attach(SelectionSurface s) {
    _surface?.removeListener(_forward);
    _surface = s;
    s.addListener(_forward);
  }

  void detach(SelectionSurface s) {
    if (_surface != s) return;
    s.removeListener(_forward);
    _surface = null;
  }
}
