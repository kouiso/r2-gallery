/// 動画の縦ドラッグで明るさ・音量を動かす計算。画面に依らない純粋な関数だけを置く。
///
/// 急に明るく・大音量になるのを防ぐ決まり:
/// - 起点は端末の実際の値（呼び出し側が読んだもの）。固定値へ飛ばさない
/// - [deadZone] を超えるまでは値を変えない（短い接触や小さな揺れで動かさない）
/// - 画面の高さ全部ではなく [span] の割合で 0〜100% を動かす
/// - 1 回の更新で動く量は [maxStep] まで（指が急に飛んでも一気には変えない）
class LevelGesture {
  /// 縦に動かし始めるまでの余裕（論理ピクセル）。
  static const deadZone = 16.0;

  /// 画面の高さに対する割合。これだけ動かすと 0%→100%。
  static const span = 0.7;

  /// 1 回の更新で動かせる最大の量（0〜1）。
  static const maxStep = 0.05;

  /// 真っ暗にすると戻す操作が見えなくなるので明るさには下限を残す。
  static const minBrightness = 0.02;
  static const maxBrightness = 1.0;
  static const minVolume = 0.0;
  static const maxVolume = 1.0;

  final double base;
  final double min;
  final double max;

  /// 起点の値からいま出している値。
  double _level;

  /// ドラッグの累計（下向きが正）。
  double _travel = 0;

  LevelGesture({required this.base, required this.min, required this.max})
      : _level = base.clamp(min, max).toDouble();

  double get level => _level;

  /// 起点から変わったか。変わっていなければ端末へ書き込まない。
  bool get moved => _level != base.clamp(min, max).toDouble();

  /// 指が [dy] だけ動いた（下向きが正）。反映後の値を返す。
  /// 余裕を越えた分だけを数えるので、越えた瞬間に値が跳ねず、余裕の中へ戻れば起点へ戻る。
  double update(double dy, double height) {
    _travel += dy;
    if (height <= 0) return _level;
    final over = _travel.abs() > deadZone
        ? _travel - (_travel.isNegative ? -deadZone : deadZone)
        : 0.0;
    final raw = base.clamp(min, max) - over / (height * span);
    final target = raw.clamp(min, max).toDouble();
    final step = (target - _level).clamp(-maxStep, maxStep).toDouble();
    _level = (_level + step).clamp(min, max).toDouble();
    // 1 回の上限や端で止められた分は捨てる。累計に残すと、指を戻しても残りの分だけ元の向きに動き続ける
    if ((raw - _level).abs() > 1e-9) {
      _travel = _travelFor(_level, height);
    }
    return _level;
  }

  /// いま出している値になる指の累計。余裕の分は動いた向きに含める。
  double _travelFor(double level, double height) {
    final over = (base.clamp(min, max) - level) * height * span;
    if (over == 0) return 0;
    return over + (over.isNegative ? -deadZone : deadZone);
  }
}

/// 表示用の 0〜100。
int percentOf(double v) => (v.clamp(0.0, 1.0) * 100).round();
