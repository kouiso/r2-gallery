import '../api/client.dart';
import '../api/models.dart';

/// ゴミ箱へ送った1件の控え。Worker が返す trashKey だけが元に戻す手段なので、
/// 一括処理の中で捨てずに呼び出し側まで返す。
class TrashReceipt {
  final String lib;
  final String trashKey;
  const TrashReceipt(this.lib, this.trashKey);
}

/// [trashAll] の結果。[receipts] は戻せる分、[failed] はゴミ箱へ送れなかった件数。
class TrashOutcome {
  final List<TrashReceipt> receipts;
  final int trashed;
  final int failed;
  const TrashOutcome(this.receipts, this.trashed, this.failed);
}

/// (ライブラリ, キー) をまとめてゴミ箱へ送る。
/// 1件ずつ直列だと数十件で待たされるが、全部同時だと Worker の同時接続を食い潰すので 8 件ずつ流す（KMP 版と同じ）。
Future<TrashOutcome> trashAll(
  ApiClient api,
  List<({String lib, String key})> targets,
) async {
  final receipts = <TrashReceipt>[];
  var trashed = 0;
  var failed = 0;
  for (var i = 0; i < targets.length; i += 8) {
    final batch = targets.sublist(i, i + 8 > targets.length ? targets.length : i + 8);
    final results = await Future.wait(batch.map((t) async {
      try {
        return (ok: true, lib: t.lib, trashKey: await api.trash(t.lib, t.key));
      } on Exception {
        // 理由はまとめて「N件を移せませんでした」と出すので、ここでは数えるだけ
        return (ok: false, lib: t.lib, trashKey: '');
      }
    }));
    for (final r in results) {
      if (!r.ok) {
        failed++;
        continue;
      }
      trashed++;
      // trashKey が返らない古い Worker では移せても戻せない。失敗扱いにはせず、戻す対象から外すだけにする
      if (r.trashKey.isNotEmpty) receipts.add(TrashReceipt(r.lib, r.trashKey));
    }
  }
  return TrashOutcome(receipts, trashed, failed);
}

/// まとめて戻した結果。理由ごとに数えるのは、利用者に出す文言が理由で変わるから。
class RestoreOutcome {
  final int total;
  final int restored;
  final int conflict;
  final int readOnly;
  final int notFound;
  final int other;
  const RestoreOutcome({
    required this.total,
    required this.restored,
    this.conflict = 0,
    this.readOnly = 0,
    this.notFound = 0,
    this.other = 0,
  });

  int get failed => total - restored;
}

Future<RestoreOutcome> restoreAll(
  ApiClient api,
  List<TrashReceipt> receipts,
) async {
  var restored = 0, conflict = 0, readOnly = 0, notFound = 0, other = 0;
  for (final r in receipts) {
    try {
      await api.restore(r.lib, r.trashKey);
      restored++;
    } on ApiError catch (e) {
      switch (e.status) {
        case 409:
          conflict++;
        case 403:
          readOnly++;
        case 404:
          notFound++;
        default:
          other++;
      }
    } on Exception {
      other++;
    }
  }
  return RestoreOutcome(
    total: receipts.length,
    restored: restored,
    conflict: conflict,
    readOnly: readOnly,
    notFound: notFound,
    other: other,
  );
}

/// 1件の復元に失敗した理由の文言。
String restoreFailureMessage(int status) => switch (status) {
      409 => '同じ名前の項目が元の場所にあるため戻せませんでした',
      // 読み取り専用ライブラリへの書き込み。再試行しても直らないので、そう伝える
      403 => 'このライブラリは読み取り専用のため、戻せません',
      // 別の端末などで先に戻されている。一覧が古いだけなので読み直す側で整える
      404 => 'すでに元の場所に戻されています',
      _ => '戻せませんでした。もう一度お試しください',
    };

/// まとめて戻した後に出す文言。全部戻れば null。
String? restoreSummaryMessage(RestoreOutcome r) {
  if (r.failed == 0) return null;
  // 同名衝突は利用者が元の場所を見に行けば解決できるので、件数より先に理由を出す（KMP 版と同じ）
  if (r.conflict > 0) return restoreFailureMessage(409);
  if (r.readOnly == r.failed) return restoreFailureMessage(403);
  if (r.notFound == r.failed) return restoreFailureMessage(404);
  return '${r.total}件中${r.failed}件を戻せませんでした';
}
