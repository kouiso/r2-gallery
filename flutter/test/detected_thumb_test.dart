import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// testWidgets のある file では HTTP が差し替えられて本物の通信ができないので、表示の確認は
// detected_thumb_ui_test.dart に分けている
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:r2_gallery/src/webdl/detected.dart';
import 'package:r2_gallery/src/webdl/detected_thumb.dart';
import 'package:r2_gallery/src/webdl/hls.dart';
import 'package:r2_gallery/src/webdl/web_fetcher.dart';

/// 閲覧先のサイトの代わり。本物の HTTP で画像・プレイリスト・セグメントを返し、来た要求を数える。
class _Site {
  late final HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';
  final Map<String, List<int>> files = {};
  final Set<String> withLength = {};
  final List<String> hits = [];
  final List<Map<String, String?>> headersSeen = [];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      hits.add(r.uri.path);
      headersSeen.add({
        'cookie': r.headers.value('cookie'),
        'referer': r.headers.value('referer'),
      });
      if (r.uri.path == '/p/drip.jpg') {
        // 1 KB ずつ 10 秒かけて流す巨大な応答。受け取りを途中でやめなければ、取り終わるまで返ってこない
        try {
          for (var i = 0; i < 1000; i++) {
            r.response.add(List.filled(1024, 3));
            await r.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await r.response.close();
        } on Object catch (e) {
          // 受け取り側が途中で切った。流し続けずに終える
          stderr.writeln('drip stopped by the client: $e');
        }
        return;
      }
      final body = files[r.uri.path];
      if (body == null) {
        r.response.statusCode = 404;
      } else {
        // 指定した物だけ Content-Length を付け、他は chunked で流す（上限の 2 つの見方を両方通す）
        if (withLength.contains(r.uri.path)) r.response.contentLength = body.length;
        r.response.add(body);
      }
      await r.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4)));

void main() {
  late _Site site;
  late Directory tmp;
  final frames = <String>[];
  final frameHeaders = <Map<String, String>>[];
  final segmentBytesSeen = <List<int>>[];

  final shrunk = <Uint8List>[];

  DetectedThumbs make({Uint8List? frame}) => DetectedThumbs(
        fetcher: WebFetcher(),
        shrinkImage: (b) async {
          shrunk.add(b);
          return Uint8List.fromList([9, 9]);
        },
        tempDir: () async => tmp,
        videoFrame: (video, headers) async {
          frames.add(video);
          frameHeaders.add(headers);
          if (!video.startsWith('http')) {
            segmentBytesSeen.add(await File(video).readAsBytes());
          }
          return frame ?? _png();
        },
      );

  setUp(() async {
    site = _Site();
    await site.start();
    tmp = await Directory.systemTemp.createTemp('r2g-thumb-test-');
    frames.clear();
    frameHeaders.clear();
    segmentBytesSeen.clear();
    shrunk.clear();
  });

  tearDown(() async {
    await site.stop();
    await tmp.delete(recursive: true);
  });

  group('サムネの作り方', () {
    test('画像はページと同じヘッダで取り、縮小した物を返す', () async {
      site.files['/p/a.jpg'] = _png();
      final t = make();
      final got = await t.of(DetectedItem('${site.base}/p/a.jpg',
          DetectedKind.image, {'Referer': 'https://page.example/'}));
      expect(shrunk.single, _png());
      expect(got, [9, 9]);
      expect(site.headersSeen.single['referer'], 'https://page.example/');
    });

    test('同じ URL は 1 回だけ取りに行く', () async {
      site.files['/p/a.jpg'] = _png();
      final t = make();
      final d = DetectedItem('${site.base}/p/a.jpg', DetectedKind.image);
      await t.of(d);
      await t.of(d);
      expect(site.hits, ['/p/a.jpg']);
    });

    test('取れない画像（404）は null にしてアイコンに任せる', () async {
      final t = make();
      expect(
          await t.of(DetectedItem('${site.base}/p/none.jpg', DetectedKind.image)),
          isNull);
    });

    test('動画は再生部品に URL を渡す。閲覧サイトの Cookie は渡さない', () async {
      final t = make();
      final url = '${site.base}/v/clip.mp4';
      await t.of(DetectedItem(url, DetectedKind.video,
          {'Cookie': 'session=secret', 'Referer': 'https://page.example/'}));
      expect(frames, [url]);
      expect(frameHeaders.single, {'Referer': 'https://page.example/'});
    });

    test('動画はブラウザ側で抜いた実コマ（data URL）があれば通信も再生部品も要らない', () async {
      final t = make();
      final d = DetectedItem(
          '${site.base}/v/clip.mp4',
          DetectedKind.video,
          const {},
          '',
          '',
          'data:image/jpeg;base64,${base64Encode(_png())}');
      expect(await t.of(d), [9, 9]);
      expect(shrunk.single, _png());
      expect(site.hits, isEmpty);
      expect(frames, isEmpty);
    });

    test('実コマが無い動画は本体の先頭を Cookie 込みで取ってコマを抜く', () async {
      site.files['/v/clip.mp4'] = [7, 7, 7];
      final t = make();
      final d = DetectedItem('${site.base}/v/clip.mp4', DetectedKind.video,
          {'Cookie': 'session=secret', 'Referer': 'https://page.example/'});
      expect(await t.of(d), isNotNull);
      // 取った先頭は一時ファイル経由で再生部品へ渡し、終わったら消す
      expect(frames.single.startsWith(tmp.path), isTrue);
      expect(segmentBytesSeen.single, [7, 7, 7]);
      expect(tmp.listSync(), isEmpty);
      // 取得役は取り込みと同じく Cookie を送る（Cookie 必須サイトでも届く）
      expect(site.headersSeen.single['cookie'], 'session=secret');
      expect(site.headersSeen.single['referer'], 'https://page.example/');
    });

    test('動画本体は上限の先頭分だけ取る', () async {
      site.files['/v/big.mp4'] = List.filled(10, 8);
      final t = DetectedThumbs(
        fetcher: WebFetcher(),
        tempDir: () async => tmp,
        maxVideoPrefixBytes: 4,
        videoFrame: (video, headers) async {
          if (!video.startsWith('http')) {
            segmentBytesSeen.add(await File(video).readAsBytes());
          }
          return _png();
        },
      );
      expect(
          await t.of(DetectedItem('${site.base}/v/big.mp4', DetectedKind.video)),
          isNotNull);
      expect(segmentBytesSeen.single, [8, 8, 8, 8]);
    });

    test('動画の実コマが両方取れず表紙があれば、その画像を縮小して使う', () async {
      site.files['/p/cover.jpg'] = _png();
      final t = make();
      final d = DetectedItem('${site.base}/v/clip.mp4', DetectedKind.video,
          {'Referer': 'https://page.example/'}, '${site.base}/p/cover.jpg');
      final got = await t.of(d);
      expect(got, [9, 9]);
      expect(frames, isEmpty);
      // 先に本体の先頭を試してから（404）表紙に回る
      expect(site.hits, ['/v/clip.mp4', '/p/cover.jpg']);
      expect(site.headersSeen.last['referer'], 'https://page.example/');
    });

    test('実コマも表紙も取れなければ動画は従来のコマ抜きに回る', () async {
      final t = make();
      final d = DetectedItem('${site.base}/v/clip.mp4', DetectedKind.video,
          const {}, '${site.base}/p/missing.jpg');
      expect(await t.of(d), isNotNull);
      expect(site.hits, ['/v/clip.mp4', '/p/missing.jpg']);
      expect(frames, ['${site.base}/v/clip.mp4']);
    });

    test('HLS でもサイトの表紙があればセグメントを取らず表紙を使う', () async {
      site.files['/p/cover.jpg'] = _png();
      final t = make();
      final d = DetectedItem('${site.base}/h/master.m3u8', DetectedKind.hls,
          const {}, '${site.base}/p/cover.jpg');
      expect(await t.of(d), [9, 9]);
      expect(site.hits, ['/p/cover.jpg']);
      expect(frames, isEmpty);
    });

    test('表紙が後から届いた検出は、URL だけ同じな古いサムネを使い回さない', () async {
      final t = make();
      final noPoster = DetectedItem(
          '${site.base}/v/clip.mp4', DetectedKind.video, const {});
      await t.of(noPoster);
      site.files['/p/cover.jpg'] = _png();
      final withPoster = noPoster.withMeta(
          poster: '${site.base}/p/cover.jpg');
      expect(await t.of(withPoster), [9, 9]);
      // 1 回目は本体先頭（404）、2 回目も同じく本体を試してから表紙
      expect(site.hits,
          ['/v/clip.mp4', '/v/clip.mp4', '/p/cover.jpg']);
    });

    test('HLS は一番軽い画質の最初のセグメントだけ取って 1 コマ抜く', () async {
      site.files['/h/master.m3u8'] = '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=5000000\nhigh.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=300000\nlow.m3u8\n'
          .codeUnits;
      site.files['/h/low.m3u8'] =
          '#EXTM3U\n#EXTINF:4,\nseg0.ts\n#EXTINF:4,\nseg1.ts\n'.codeUnits;
      site.files['/h/seg0.ts'] = [1, 2, 3, 4];
      final t = make();
      final got = await t.of(
          DetectedItem('${site.base}/h/master.m3u8', DetectedKind.hls));
      expect(got, isNotNull);
      expect(site.hits, ['/h/master.m3u8', '/h/low.m3u8', '/h/seg0.ts']);
      expect(segmentBytesSeen.single, [1, 2, 3, 4]);
      // 抜き出しに使った一時ファイルは残さない
      expect(tmp.listSync(), isEmpty);
    });

    test('一番軽い変種が音声だけなら、映像のある一番軽い変種から 1 コマ抜く', () async {
      site.files['/h/av.m3u8'] = '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=232370,CODECS="mp4a.40.2, avc1.4d4015"\nv1.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=41457,CODECS="mp4a.40.2"\na0.m3u8\n'
          .codeUnits;
      site.files['/h/v1.m3u8'] = '#EXTM3U\n#EXTINF:4,\nv1seg0.ts\n'.codeUnits;
      site.files['/h/v1seg0.ts'] = [5, 6, 7];
      final t = make();
      final got =
          await t.of(DetectedItem('${site.base}/h/av.m3u8', DetectedKind.hls));
      expect(got, isNotNull);
      expect(site.hits, ['/h/av.m3u8', '/h/v1.m3u8', '/h/v1seg0.ts']);
      expect(segmentBytesSeen.single, [5, 6, 7]);
    });

    test('暗号化された HLS はセグメントを取らずにアイコンに任せる', () async {
      site.files['/h/enc.m3u8'] = '#EXTM3U\n'
              '#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXTINF:4,\nseg0.ts\n'
          .codeUnits;
      final t = make();
      expect(
          await t.of(DetectedItem('${site.base}/h/enc.m3u8', DetectedKind.hls)),
          isNull);
      expect(site.hits, ['/h/enc.m3u8']);
      expect(frames, isEmpty);
    });

    test('上限を超える画像は受け取りを途中でやめ、縮小もせずアイコンに任せる', () async {
      site.files['/p/big-len.jpg'] = List.filled(5000, 1);
      site.withLength.add('/p/big-len.jpg');
      site.files['/p/big-chunked.jpg'] = List.filled(5000, 1);
      final t = DetectedThumbs(
        fetcher: WebFetcher(),
        maxImageBytes: 1000,
        shrinkImage: (b) async {
          shrunk.add(b);
          return b;
        },
      );
      // Content-Length で先に分かる時と、chunked で受け取りながら分かる時の両方
      expect(
          await t.of(DetectedItem('${site.base}/p/big-len.jpg', DetectedKind.image)),
          isNull);
      expect(
          await t.of(
              DetectedItem('${site.base}/p/big-chunked.jpg', DetectedKind.image)),
          isNull);
      expect(shrunk, isEmpty);
    });

    test('長く流れ続ける画像も、上限を超えた所で受け取りをやめてすぐ返る', () async {
      final t = DetectedThumbs(
          fetcher: WebFetcher(),
          maxImageBytes: 4096,
          shrinkImage: (b) async => b);
      final sw = Stopwatch()..start();
      final got = await t
          .of(DetectedItem('${site.base}/p/drip.jpg', DetectedKind.image))
          .timeout(const Duration(seconds: 3));
      expect(got, isNull);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('上限を超える HLS のセグメントは 1 コマ抜きに回さない', () async {
      site.files['/h/m.m3u8'] = '#EXTM3U\n#EXTINF:4,\nbig.ts\n'.codeUnits;
      site.files['/h/big.ts'] = List.filled(5000, 2);
      final t = DetectedThumbs(
        fetcher: WebFetcher(),
        tempDir: () async => tmp,
        maxSegmentBytes: 1000,
        videoFrame: (video, headers) async {
          frames.add(video);
          return null;
        },
      );
      expect(await t.of(DetectedItem('${site.base}/h/m.m3u8', DetectedKind.hls)),
          isNull);
      expect(frames, isEmpty);
    });

    test('音声はサムネを作らない', () async {
      final t = make();
      expect(
          await t.of(DetectedItem('${site.base}/a/s.mp3', DetectedKind.audio)),
          isNull);
      expect(site.hits, isEmpty);
    });

    test('同時に取りに行くのは決めた数まで', () async {
      final gate = Completer<void>();
      var running = 0;
      var peak = 0;
      final t = DetectedThumbs(
        fetcher: WebFetcher(),
        maxParallel: 2,
        videoFrame: (video, headers) async {
          running++;
          if (running > peak) peak = running;
          await gate.future;
          running--;
          return null;
        },
      );
      final all = [
        for (var i = 0; i < 5; i++)
          t.of(DetectedItem('${site.base}/v/$i.mp4', DetectedKind.video)),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(peak, 2);
      gate.complete();
      await Future.wait(all);
      expect(peak, 2);
    });
  });

  test('HLS の画質選びは、指定すれば一番軽い物を選ぶ', () {
    const m = '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000\nmid.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=200000\nlow.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3000000\nhigh.m3u8\n';
    expect(hlsVariant(m, 'https://x.test/m.m3u8'), 'https://x.test/high.m3u8');
    expect(hlsVariant(m, 'https://x.test/m.m3u8', lowest: true),
        'https://x.test/low.m3u8');
  });

  group('HLS の一番軽い画質選びは音声だけの変種を飛ばす', () {
    // Apple の見本 bipbop_4x3_variant.m3u8 をそのまま写した物（2026-10-22 取得）。
    // 一番軽い gear0 は音声だけ（fileSequence0.aac）で、映像のある一番軽い物は gear1
    const bipbop = '#EXTM3U\n\n\n'
        '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=232370,CODECS="mp4a.40.2, avc1.4d4015"\n'
        'gear1/prog_index.m3u8\n\n'
        '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=649879,CODECS="mp4a.40.2, avc1.4d401e"\n'
        'gear2/prog_index.m3u8\n\n'
        '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=991714,CODECS="mp4a.40.2, avc1.4d401e"\n'
        'gear3/prog_index.m3u8\n\n'
        '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1927833,CODECS="mp4a.40.2, avc1.4d401f"\n'
        'gear4/prog_index.m3u8\n\n'
        '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=41457,CODECS="mp4a.40.2"\n'
        'gear0/prog_index.m3u8\n';
    const base = 'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
        'bipbop_4x3/bipbop_4x3_variant.m3u8';

    test('bipbop では gear0 ではなく gear1 を選ぶ', () {
      expect(hlsVariant(bipbop, base, lowest: true),
          'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear1/prog_index.m3u8');
    });

    test('最高画質の選び方は変わらない', () {
      expect(hlsVariant(bipbop, base),
          'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear4/prog_index.m3u8');
    });

    test('CODECS が無い時は、RESOLUTION の無い変種を音声だけと見なす', () {
      const m = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=64000\naudio.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nsd.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720\nhd.m3u8\n';
      expect(hlsVariant(m, 'https://x.test/m.m3u8', lowest: true),
          'https://x.test/sd.m3u8');
    });

    test('知らない映像 codec でも RESOLUTION があれば映像ありと見なす', () {
      const m = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=50000,CODECS="mp4a.40.2"\na.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="xyz1.1,mp4a.40.2",RESOLUTION=640x360\nv.m3u8\n';
      expect(hlsVariant(m, 'https://x.test/m.m3u8', lowest: true),
          'https://x.test/v.m3u8');
    });

    test('全部が音声だけなら、従来どおり一番軽い物を選ぶ', () {
      const m = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"\nhi.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.5"\nlo.m3u8\n';
      expect(hlsVariant(m, 'https://x.test/m.m3u8', lowest: true),
          'https://x.test/lo.m3u8');
    });
  });
}
