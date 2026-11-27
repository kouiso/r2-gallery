/// 端末の既定の回線の様子。Wi‑Fi 限定の設定（#27）がどの回線で動いてよいかを決めるのに使う。
class NetState {
  const NetState({
    required this.online,
    required this.wifi,
    required this.metered,
    required this.dataSaver,
  });

  /// 既定の回線にインターネットがある
  final bool online;

  /// Wi‑Fi か有線。従量制かどうかは問わない（設定の名前「Wi‑Fi接続時のみ」に合わせる）
  final bool wifi;

  /// 従量制の回線
  final bool metered;

  /// 端末の省データ設定がこのアプリに効いている
  final bool dataSaver;

  /// 回線の種類が分からんがオンライン。Wi‑Fi 限定の行も待たせない。
  /// 古い端末側（bool しか流さない）や読めない値の時に使い、転送を止めたままにしない
  static const unknownOnline =
      NetState(online: true, wifi: true, metered: false, dataSaver: false);

  static const offline =
      NetState(online: false, wifi: false, metered: false, dataSaver: false);

  /// EventChannel の値。bool（古い端末側）と Map を読む。読めなければ null。
  /// Map の欄が欠けたり型が違ったりした時は、その欄だけ unknownOnline の値で埋める
  /// （端末側の取り違えで「ずっとオフライン」になり、配った版の転送が全部止まるのを避ける）。
  static NetState? fromEvent(Object? e) {
    if (e is bool) return e ? unknownOnline : offline;
    if (e is! Map) return null;
    bool field(String k, bool fallback) {
      final v = e[k];
      return v is bool ? v : fallback;
    }

    return NetState(
      online: field('online', unknownOnline.online),
      wifi: field('wifi', unknownOnline.wifi),
      metered: field('metered', unknownOnline.metered),
      dataSaver: field('dataSaver', unknownOnline.dataSaver),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NetState &&
      other.online == online &&
      other.wifi == wifi &&
      other.metered == metered &&
      other.dataSaver == dataSaver;

  @override
  int get hashCode => Object.hash(online, wifi, metered, dataSaver);

  @override
  String toString() =>
      'NetState(online: $online, wifi: $wifi, metered: $metered, dataSaver: $dataSaver)';
}
