import 'kv.dart';

/// 再ロックまでの猶予の既定値（KMP版 RELOCK_GRACE_DEFAULT_MS と同じ 1 時間）。
const relockGraceDefaultMs = 3600000;

/// 再ロックまでの時間の選択肢（ms → 表示名）。KMP版の GRACE_OPTIONS と同じ並び。
const graceOptions = <(int, String)>[
  (0, '毎回ロック'),
  (60000, '1分'),
  (600000, '10分'),
  (1800000, '30分'),
  (3600000, '1時間'),
  (21600000, '6時間'),
  (43200000, '12時間'),
  (86400000, '24時間'),
];

String graceLabel(int ms) {
  for (final o in graceOptions) {
    if (o.$1 == ms) return o.$2;
  }
  return '${ms ~/ 60000}分';
}

/// 起動時にロック画面を出すか。端末の画面ロックは既定でON（このアプリは非公開が前提）。
/// web は端末認証が使えないので、PIN を決めている時だけ守る。
bool shouldGateAtStart({
  required bool hasPin,
  required bool deviceLockEnabled,
  required bool isWeb,
}) =>
    hasPin || (deviceLockEnabled && !isWeb);

/// 「今すぐロック」や再ロックが実際に何かをロックできるか。
/// 認証手段が無いまま画面だけ覆うと、利用者が自力で抜けられなくなる。
/// deviceAvailable は「無いと確かめられていない」の意味で渡す。問い合わせの失敗で
/// ロックを外す側に倒すと、端末の不調だけで中身が見えてしまう。
bool canLockNow({
  required bool hasPin,
  required bool deviceLockEnabled,
  required bool deviceAvailable,
}) =>
    hasPin || (deviceLockEnabled && deviceAvailable);

/// バックグラウンドから戻った時に再ロックするか。猶予ちょうどはまだ許す（KMP版と同じ `>`）。
bool shouldRelock({
  required int? elapsedMs,
  required int graceMs,
  required bool locked,
  required bool canLock,
}) {
  if (elapsedMs == null || locked || !canLock) return false;
  return elapsedMs > graceMs;
}

/// ファイル選択など、アプリが自分で開いた外部画面の間に裏へ回った時の猶予の下限。
/// 「毎回ロック」でも選んで戻るたびにロックされると取り込めん。かといって無制限に見逃すと、
/// ピッカーを開いたまま放置された端末を素通りさせることになる。
const externalActivityGraceMs = 600000;

int effectiveGraceMs({required int graceMs, required bool duringExternal}) =>
    duringExternal && graceMs < externalActivityGraceMs
        ? externalActivityGraceMs
        : graceMs;

/// 画面ロック・再ロック猶予の保存値。
class LockSettings {
  static Future<bool> deviceLockEnabled() async =>
      (await Kv.get(Keys.deviceLock)) != '0';

  static Future<void> setDeviceLockEnabled(bool on) =>
      Kv.set(Keys.deviceLock, on ? '1' : '0');

  static Future<int> relockGraceMs() async {
    final v = int.tryParse(await Kv.get(Keys.lockGraceMs) ?? '');
    return (v != null && v >= 0) ? v : relockGraceDefaultMs;
  }

  static Future<void> setRelockGraceMs(int ms) =>
      Kv.set(Keys.lockGraceMs, ms.toString());
}
