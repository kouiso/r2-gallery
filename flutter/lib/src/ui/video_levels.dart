import 'package:flutter/material.dart';

import '../viewer/level_gesture.dart';

/// ドラッグ中に出す「何を・いくつに」。動かす前から現在値を見せる。
class LevelBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final int percent;
  const LevelBadge({
    super.key,
    required this.icon,
    required this.label,
    required this.percent,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '$label $percent%',
      child: ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(width: 10),
            SizedBox(
              width: 100,
              child: LinearProgressIndicator(
                value: percent / 100,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 44,
              child: Text('$percent%',
                  textAlign: TextAlign.end,
                  style: const TextStyle(color: Color(0xFFFFAE00))),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 案内の背景（黒 60%）と文字色。真っ白な動画の上でも文字のコントラスト比が
/// 4.5 以上になる値（白動画 + 黒 60% = 灰 102 に白文字で約 5.7）。
const kLevelHintScrim = Color(0x99000000);
const kLevelHintForeground = Colors.white;

/// 操作バーが出ている間、画面の左右の端に「ここを上下にドラッグすると何が変わるか」を置く。
/// 触れない飾り。同じ操作はパネルのスライダーでもできる。
class LevelEdgeHint extends StatelessWidget {
  final IconData icon;
  final String label;
  const LevelEdgeHint({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Container(
          decoration: BoxDecoration(
            color: kLevelHintScrim,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.keyboard_arrow_up, color: kLevelHintForeground, size: 18),
            Icon(icon, color: kLevelHintForeground, size: 20),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: kLevelHintForeground, fontSize: 11)),
            const Icon(Icons.keyboard_arrow_down,
                color: kLevelHintForeground, size: 18),
          ]),
        ),
      ),
    );
  }
}

/// 操作バーの「明るさ・音量」で開く、スライダーでの操作と使い方の説明。
/// 値は端末の実値。読めない値は動かせない理由を出し、実値のように見せない。
class LevelPanel extends StatelessWidget {
  final double? brightness;

  /// 端末から読めたか。読む前は null。
  final bool? brightnessReadable;

  /// 明るさを読めない理由が、端末の自動調整中だから。
  final bool brightnessAuto;
  final double? volume;
  final bool? volumeReadable;
  final ValueChanged<double> onBrightness;
  final ValueChanged<double> onVolume;
  final ValueChanged<bool> onSliding;

  const LevelPanel({
    super.key,
    required this.brightness,
    required this.brightnessReadable,
    this.brightnessAuto = false,
    required this.volume,
    required this.volumeReadable,
    required this.onBrightness,
    required this.onVolume,
    required this.onSliding,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('level-panel'),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _row(
          icon: Icons.wb_sunny,
          label: '明るさ',
          value: brightness,
          min: LevelGesture.minBrightness,
          unavailable: brightnessReadable == false
              ? (brightnessAuto
                  ? '自動調整中のため明るさを読めません。端末の設定でオフにすると変えられます'
                  : '明るさはこの環境では変えられません')
              : null,
          onChanged: onBrightness,
        ),
        _row(
          icon: Icons.volume_up,
          label: '音量',
          value: volume,
          min: LevelGesture.minVolume,
          unavailable: volumeReadable == false ? '音量はこの環境では変えられません' : null,
          onChanged: onVolume,
        ),
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '画面の左側を上下になぞると明るさ、右側を上下になぞると音量が変わります。'
            '動画を閉じるか別のアプリへ移ると、明るさは端末の設定に戻ります。',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ),
      ]),
    );
  }

  Widget _row({
    required IconData icon,
    required String label,
    required double? value,
    required double min,
    required String? unavailable,
    required ValueChanged<double> onChanged,
  }) {
    final enabled = unavailable == null && value != null;
    final pct = value == null ? null : percentOf(value);
    return Row(children: [
      Icon(icon, color: enabled ? Colors.white : Colors.white38),
      const SizedBox(width: 8),
      SizedBox(
        width: 44,
        child: Text(label,
            style: TextStyle(
                color: enabled ? Colors.white : Colors.white38, fontSize: 13)),
      ),
      Expanded(
        child: enabled
            ? Slider(
                key: ValueKey('level-$label'),
                value: value.clamp(min, 1.0).toDouble(),
                min: min,
                max: 1,
                divisions: 100,
                label: '$pct%',
                semanticFormatterCallback: (v) => '$label ${percentOf(v)}%',
                activeColor: Colors.white,
                inactiveColor: Colors.white30,
                onChangeStart: (_) => onSliding(true),
                onChanged: onChanged,
                onChangeEnd: (_) => onSliding(false),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(unavailable ?? '読み取り中…',
                    key: ValueKey('level-$label-unavailable'),
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
      ),
      SizedBox(
        width: 44,
        child: Text(pct == null ? '--' : '$pct%',
            textAlign: TextAlign.end,
            style: const TextStyle(color: Color(0xFFFFAE00), fontSize: 13)),
      ),
    ]);
  }
}
