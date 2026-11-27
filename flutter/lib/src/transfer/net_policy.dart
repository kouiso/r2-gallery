import 'net_state.dart';

/// どの回線で転送してよいかの設定（#27）。既定は今まで通りモバイル回線でも動く。
/// 理由: 設定を変えていない人の動きを変えない
class TransferNetPolicy {
  const TransferNetPolicy({this.uploadWifiOnly = false, this.downloadWifiOnly = false});

  /// 写真・動画のアップロードと、取り込んだ物の R2 への送信を Wi‑Fi に限る
  final bool uploadWifiOnly;

  /// ネットからの取り込み（取得）とオフライン保存を Wi‑Fi に限る。
  /// 一覧の表示・サムネ・再生・「端末に保存」は入れない（止めると普段の閲覧が壊れる）
  final bool downloadWifiOnly;

  @override
  bool operator ==(Object other) =>
      other is TransferNetPolicy &&
      other.uploadWifiOnly == uploadWifiOnly &&
      other.downloadWifiOnly == downloadWifiOnly;

  @override
  int get hashCode => Object.hash(uploadWifiOnly, downloadWifiOnly);

  @override
  String toString() =>
      'TransferNetPolicy(uploadWifiOnly: $uploadWifiOnly, downloadWifiOnly: $downloadWifiOnly)';
}

/// 転送の向き。取り込みは取得（download）と送信（upload）の 2 段で、段ごとに設定を見る
enum TransferLeg { upload, download }

/// 転送を待たせる理由
enum NetWait { offline, wifi, dataSaver }

/// 今の回線とこの設定で、その段を動かしてよいか。動いてよければ null、待つなら理由。
/// 両方のキューが同じ判定を使う。
/// 理由の順は「オフライン → Wi‑Fi → 省データ」。Wi‑Fi 待ちは前面に戻っても残るので、
/// 省データより利用者が直せる事を先に示す
NetWait? transferWait(
  NetState net,
  TransferNetPolicy policy,
  TransferLeg leg, {
  required bool foreground,
}) {
  if (!net.online) return NetWait.offline;
  final wifiOnly = switch (leg) {
    TransferLeg.upload => policy.uploadWifiOnly,
    TransferLeg.download => policy.downloadWifiOnly,
  };
  // 従量制かどうかは問わない。設定の名前（Wi‑Fi接続時のみ）と合わせる
  if (wifiOnly && !net.wifi) return NetWait.wifi;
  // OS は省データ設定が効いた従量制の回線で、裏のアプリの通信を止める。始めても失敗するだけなので待つ。
  // 設定に関係なく待たせ、前面に戻れば動かす
  if (net.dataSaver && net.metered && !foreground) return NetWait.dataSaver;
  return null;
}

/// サービスの通知へ渡す「待機の件数」。動いている行（または回線待ちの行）が 1 件でも
/// 設定で待っていない時は 0 を返し、通知は今まで通りの「転送中」のままにする。
/// 理由: 端末側は件数しか知らず、待機の行と動いている行が混ざる時に
/// 「N件が Wi‑Fi を待っています」と出すと、実際には動いている転送を隠してしまう。
/// [active] は動かす対象の行の数（待機を含む）、[waiting] はそのうち設定か省データで待っている数
int notifyWaitingCount({required int active, required int waiting}) =>
    waiting > 0 && waiting >= active ? waiting : 0;
