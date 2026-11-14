import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/offline/offline_playback_files.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';

import 'offline_store_test.dart' show MemKv;

void main() {
  test('合成データで保存動画の認証復号と再生cache準備を測る（native decodeは含めない）', () async {
    final root = await Directory.systemTemp.createTemp('r2g-startup-probe-');
    addTearDown(() => root.delete(recursive: true));
    final results = <Map<String, Object?>>[];
    for (final size in [1024 * 1024, 8 * 1024 * 1024]) {
      final data = Uint8List.fromList(List<int>.generate(size, (i) => i % 251));
      final digest = hash.sha256.convert(data).toString();
      final kv = MemKv();
      final encrypted = Directory('${root.path}/encrypted-$size');
      final seeded = OfflineStore(
        kv: kv,
        dir: () async => encrypted,
      ).forAccount('synthetic');
      await seeded.saveBytes(
        lib: 'lib',
        key: 'clip.mp4',
        type: 'video',
        name: 'synthetic bytes; not codec input',
        plain: data,
      );
      for (var sample = 0; sample < 3; sample++) {
        final reader = OfflineStore(
          kv: kv,
          dir: () async => encrypted,
        ).forAccount('synthetic');
        final cache = OfflinePlaybackFiles(
          root: () async => Directory('${root.path}/playback'),
        );
        final clock = Stopwatch()..start();
        var lastTickUs = 0;
        var maximumGapUs = 0;
        var ticks = 0;
        final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
          final now = clock.elapsedMicroseconds;
          final gap = now - lastTickUs;
          if (gap > maximumGapUs) maximumGapUs = gap;
          lastTickUs = now;
          ticks++;
        });
        addTearDown(ticker.cancel);
        final plain = await reader.readBytes('lib', 'clip.mp4');
        final decodedUs = clock.elapsedMicroseconds;
        expect(plain, isNotNull);
        final file = await cache.create(plain!);
        final preparedUs = clock.elapsedMicroseconds;
        // 同期で止まっていた場合の、最後の遅れも測る。paddingは準備時間に含めない。
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ticker.cancel();
        clock.stop();
        expect(
          hash.sha256.convert(await file.file.readAsBytes()).toString(),
          digest,
        );
        results.add({
          'bytes': size,
          'fixture_sha256': digest,
          'sample': sample,
          'ciphertext_read_and_authenticated_decrypt_us': decodedUs,
          'playback_cache_write_us': preparedUs - decodedUs,
          'local_preparation_us': preparedUs,
          'maximum_main_isolate_timer_gap_us': maximumGapUs,
          'timer_ticks': ticks,
          'first_frame_us': null,
        });
        await file.dispose();
        expect(await file.file.exists(), isFalse);
        reader.dispose();
      }
      seeded.dispose();
    }
    const dir = String.fromEnvironment('STARTUP_EVIDENCE_DIR');
    const variant = String.fromEnvironment(
      'STARTUP_EVIDENCE_VARIANT',
      defaultValue: 'unspecified',
    );
    if (dir.isNotEmpty) {
      final file = File('$dir/$variant-offline.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'scope':
              'Real Dart crypto and temporary fixture I/O; fresh reader object; filesystem cache warmed by setup writes; no codec/native/Keychain timing',
          'variant': variant,
          'samples': results,
        }),
      );
    }
  });
}
