import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'perf_rss_stub.dart' if (dart.library.io) 'perf_rss_io.dart' as rss;

/// 実機の計測口。`--dart-define=R2_PERF_LOG=true` のビルドだけ logcat に
/// `r2g.perf {...}` の 1 行 1 件 JSON を出す。既定のビルドでは何もしない
/// （#25 の完了条件が前後の数値を求め、#24・#1 も同じ部品を使うため）。
/// 画面には出さない。
class PerfLog {
  PerfLog._();

  static const enabled = bool.fromEnvironment('R2_PERF_LOG');

  static final Stopwatch _clock = Stopwatch()..start();

  /// 1 行: `r2g.perf {"t":<main からの ms>,"ev":"<name>",...fields}`。
  /// enabled が false なら何もしない。
  static void mark(String ev, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    final payload = <String, Object?>{
      't': _clock.elapsedMilliseconds,
      'ev': ev,
      ...fields,
    };
    debugPrint('r2g.perf ${jsonEncode(payload)}');
  }

  /// 5 秒ごとに ev="frames" を出す。enabled が false なら登録もしない。
  static void watchFrames() {
    if (!enabled) return;
    var n = 0;
    var jank = 0;
    var worstBuildMs = 0.0;
    var worstRasterMs = 0.0;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        n++;
        final build = t.buildDuration.inMicroseconds / 1000.0;
        final raster = t.rasterDuration.inMicroseconds / 1000.0;
        if (build > worstBuildMs) worstBuildMs = build;
        if (raster > worstRasterMs) worstRasterMs = raster;
        if (build > 16.7 || raster > 16.7) jank++;
      }
    });
    Timer.periodic(const Duration(seconds: 5), (_) {
      mark('frames', {
        'n': n,
        'jank': jank,
        'worstBuildMs': double.parse(worstBuildMs.toStringAsFixed(1)),
        'worstRasterMs': double.parse(worstRasterMs.toStringAsFixed(1)),
        'rssMiB': rss.currentRssMiB(),
        'imgBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
        'imgLive': PaintingBinding.instance.imageCache.liveImageCount,
      });
      n = 0;
      jank = 0;
      worstBuildMs = 0.0;
      worstRasterMs = 0.0;
    });
  }
}
