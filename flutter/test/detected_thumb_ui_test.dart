import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:r2_gallery/src/ui/import_parts.dart';
import 'package:r2_gallery/src/webdl/detected.dart';
import 'package:r2_gallery/src/webdl/detected_thumb.dart';
import 'package:r2_gallery/src/webdl/web_fetcher.dart';

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));

void main() {
  group('検出一覧の表示', () {
    Widget sheet(DetectedThumbs? thumbs, List<DetectedItem> items) =>
        MaterialApp(
          home: Scaffold(
            body: DetectedSheetContent(
                items: items, block: null, onSave: (_) {}, thumbs: thumbs),
          ),
        );

    testWidgets('動画の再生時間を分・秒で出し、不明な動画と画像には出さない', (tester) async {
      await tester.pumpWidget(sheet(null, const [
        DetectedItem('https://cdn.example.com/v/a.mp4', DetectedKind.video, {}, '', '',
            '', Duration(seconds: 185)),
        DetectedItem('https://cdn.example.com/v/b.mp4', DetectedKind.video, {}, '', '',
            '', Duration(seconds: 5)),
        DetectedItem('https://cdn.example.com/v/c.mp4', DetectedKind.video, {}, '', '',
            '', Duration(seconds: 65 * 60 + 2)),
        DetectedItem('https://cdn.example.com/v/unknown.mp4', DetectedKind.video),
        DetectedItem('https://cdn.example.com/p/a.jpg', DetectedKind.image),
      ]));
      expect(find.textContaining('動画 3分05秒・cdn.example.com'), findsOneWidget);
      expect(find.textContaining('動画 0分05秒・'), findsOneWidget);
      expect(find.textContaining('動画 65分02秒・'), findsOneWidget);
      // 長さが不明な動画は 0 秒と書かず、種類だけ。画像にも付けない
      expect(find.textContaining('動画・cdn.example.com'), findsOneWidget);
      expect(find.textContaining('画像・cdn.example.com'), findsOneWidget);
      expect(find.textContaining('0分00秒'), findsNothing);
    });

    test('fmtDuration は秒を四捨五入して分・秒にする', () {
      expect(fmtDuration(const Duration(seconds: 5)), '0分05秒');
      expect(fmtDuration(const Duration(seconds: 185)), '3分05秒');
      expect(fmtDuration(const Duration(seconds: 3902)), '65分02秒');
      expect(fmtDuration(const Duration(milliseconds: 4600)), '0分05秒');
      expect(fmtDuration(const Duration(milliseconds: 59600)), '1分00秒');
    });

    testWidgets('画像と動画が混ざっても全件にサムネが出る', (tester) async {
      final t = DetectedThumbs(
          fetcher: _FakeFetcher(_png()),
          shrinkImage: (b) async => b,
          videoFrame: (v, h) async => _png());
      await tester.pumpWidget(sheet(t, const [
        DetectedItem('https://cdn.example.com/p/a.jpg', DetectedKind.image),
        DetectedItem('https://cdn.example.com/v/b.mp4', DetectedKind.video),
      ]));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.descendant(of: find.byType(DetectedThumb), matching: find.byType(Image)),
          findsNWidgets(2));
      expect(find.byIcon(Icons.movie), findsNothing);
    });

    testWidgets('取れない物はアイコンになり、行の大きさは変わらない', (tester) async {
      final t = DetectedThumbs(
          fetcher: _FakeFetcher(null), videoFrame: (v, h) async => null);
      await tester.pumpWidget(sheet(t, const [
        DetectedItem('https://cdn.example.com/p/a.jpg', DetectedKind.image),
        DetectedItem('https://cdn.example.com/v/b.mp4', DetectedKind.video),
      ]));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(find.byIcon(Icons.photo), findsOneWidget);
      expect(find.byIcon(Icons.movie), findsOneWidget);
      for (final e in tester.widgetList(find.byType(DetectedThumb))) {
        expect(tester.getSize(find.byWidget(e)), const Size(48, 48));
      }
    });

    testWidgets('画像として読めない中身はアイコンに戻す', (tester) async {
      final t = DetectedThumbs(
          fetcher: _FakeFetcher(Uint8List.fromList([1, 2, 3])),
          // 縮小を通り抜けた壊れた中身でも、表示側でアイコンに戻すことを確かめる
          shrinkImage: (b) async => b,
          videoFrame: (v, h) async => null);
      await tester.pumpWidget(sheet(t, const [
        DetectedItem('https://cdn.example.com/p/broken.jpg', DetectedKind.image),
      ]));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.byIcon(Icons.photo), findsOneWidget);
    });
  });
}

/// 画像の取得だけを差し替えた取得役（表示の確認用）。null なら 404 と同じ扱いにする。
class _FakeFetcher extends WebFetcher {
  _FakeFetcher(this.bytes);
  final Uint8List? bytes;
  @override
  Future<int> download(String url, Map<String, String> headers,
      {required int resumeAt,
      required FutureOr<void> Function(Uint8List chunk) onChunk,
      required void Function(int written) onProgress,
      void Function(int total)? onTotal,
      String? origin,
      cancelToken}) async {
    final b = bytes;
    if (b == null) throw const WebFetchError(404);
    onTotal?.call(b.length);
    await onChunk(b);
    onProgress(b.length);
    return b.length;
  }
}
