import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/ui/import_parts.dart';
import 'package:r2_gallery/src/webdl/detected.dart';
import 'package:r2_gallery/src/webdl/hls.dart';
import 'package:r2_gallery/src/webdl/media_name.dart';
import 'package:r2_gallery/src/webdl/sniff_collector.dart';
import 'package:r2_gallery/src/webdl/url_policy.dart';
import 'package:r2_gallery/src/webdl/web_history.dart';
import 'package:r2_gallery/src/webdl/web_transfer.dart';

void main() {
  group('detectKind / displayName', () {
    test('動画・音声・画像・HLS を拡張子で分類する', () {
      expect(detectKind('https://cdn.example.com/a/b/clip.MP4?sig=1'),
          DetectedKind.video);
      expect(detectKind('https://x.test/v.mkv'), DetectedKind.video);
      expect(detectKind('https://x.test/song.mp3'), DetectedKind.audio);
      expect(detectKind('https://x.test/pic.webp?w=300'), DetectedKind.image);
      expect(detectKind('https://cdn.x.test/master.m3u8'), DetectedKind.hls);
      expect(detectKind('https://cdn.x.test/master.m3u8?token=abc'),
          DetectedKind.hls);
      expect(detectKind('https://x.test/page.html'), isNull);
      expect(detectKind('https://x.test/api.json'), isNull);
    });

    test('名前は URL デコードして安全な文字だけにする', () {
      final d = DetectedItem(
          'https://x.test/a/%E5%8B%95%E7%94%BB%201.mp4?t=1', DetectedKind.video);
      expect(d.displayName.endsWith('.mp4'), isTrue);
      expect(DetectedItem('https://x.test/vid.webm', DetectedKind.video)
          .displayName, 'vid.webm');
      expect(DetectedItem('https://x.test/a b?c.mp4', DetectedKind.video)
          .displayName, 'a b');
      expect(DetectedItem('https://x.test/', DetectedKind.video).displayName,
          'media');
      expect(
          DetectedItem('https://x.test/${'a' * 200}.mp4', DetectedKind.video)
              .displayName
              .length,
          80);
    });
  });

  group('HLS', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=480x270
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
https://cdn.example.com/hd/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
mid/index.m3u8
''';

    test('BANDWIDTH 最大の変種を選ぶ', () {
      expect(hlsVariant(master, 'https://cdn.example.com/master.m3u8'),
          'https://cdn.example.com/hd/index.m3u8');
    });

    test('AVERAGE-BANDWIDTH を BANDWIDTH と取り違えない', () {
      const m = '''
#EXTM3U
#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=9000000,BANDWIDTH=1000
a.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000,AVERAGE-BANDWIDTH=1
b.m3u8
''';
      expect(hlsVariant(m, 'https://x.test/m.m3u8'), 'https://x.test/b.m3u8');
    });

    test('相対の変種は基準 URL から解決する', () {
      const only = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow/index.m3u8';
      expect(hlsVariant(only, 'https://cdn.example.com/streams/master.m3u8'),
          'https://cdn.example.com/streams/low/index.m3u8');
    });

    test('メディアプレイリストは変種なし、セグメントを順に返す', () {
      const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:10.0,
seg-1.ts
#EXTINF:10.0,
seg-2.ts
#EXT-X-ENDLIST
''';
      expect(hlsVariant(media, 'https://x.test/v/index.m3u8'), isNull);
      expect(hlsIsMaster(media), isFalse);
      expect(hlsIsMaster(master), isTrue);
      expect(hlsSegments(media, 'https://x.test/v/index.m3u8'),
          ['https://x.test/v/seg-1.ts', 'https://x.test/v/seg-2.ts']);
    });

    test('絶対パス・プロトコル相対・相対のセグメントを解決する', () {
      const media = '''
#EXTM3U
#EXTINF:4.0,
/abs/seg1.ts
#EXTINF:4.0,
//other.cdn/seg2.ts
#EXTINF:4.0,
seg3.ts
''';
      expect(hlsSegments(media, 'https://cdn.test/v/list.m3u8'), [
        'https://cdn.test/abs/seg1.ts',
        'https://other.cdn/seg2.ts',
        'https://cdn.test/v/seg3.ts',
      ]);
    });

    test('暗号化と fMP4 を見分ける', () {
      expect(hlsIsEncrypted('#EXT-X-KEY:METHOD=AES-128,URI="k"\nseg.ts'), isTrue);
      expect(hlsIsEncrypted('#EXT-X-KEY:METHOD=NONE\nseg.ts'), isFalse);
      expect(hlsIsEncrypted('#EXTINF:1,\nseg.ts'), isFalse);
      expect(hlsNeedsInitSegment('#EXT-X-MAP:URI="init.mp4"\nseg.m4s'), isTrue);
    });
  });

  group('SniffCollector', () {
    const mp4 = 'https://cdn.example.com/v/clip.mp4?sig=1';

    test('通信由来はリクエストのヘッダを守り、Cookie と Referer は無い時だけ補う', () {
      final c = SniffCollector();
      final item = c.capture(
          mp4, {'Range': 'bytes=0-', 'Cookie': 'req=1'},
          cookie: 'sess=abc', referer: 'https://example.com/page');
      expect(item?.kind, DetectedKind.video);
      expect(item?.headers['Range'], 'bytes=0-');
      expect(item?.headers['Cookie'], 'req=1');
      expect(item?.headers['Referer'], 'https://example.com/page');
      expect(c.list(), [item]);
    });

    test('リクエストに Cookie が無ければ Cookie の入れ物から補う', () {
      final c = SniffCollector();
      final item = c.capture(mp4, {'User-Agent': 'UA'},
          cookie: 'sess=abc', referer: null);
      expect(item?.headers['Cookie'], 'sess=abc');
      expect(item?.headers.containsKey('Referer'), isFalse);
    });

    test('画像とメディアでない URL は通信から拾わない', () {
      final c = SniffCollector();
      expect(c.capture('https://x/a.png', null), isNull);
      expect(c.capture('https://x/index.html', null), isNull);
      expect(c.list(), isEmpty);
    });

    test('通信で拾った方が DOM 走査より優先される', () {
      final c = SniffCollector();
      final sniffed = c.capture(mp4, {'Cookie': 'req=1'});
      c.addFromPage(mp4, {'User-Agent': 'UA', 'Referer': 'https://p'});
      expect(c.list(), hasLength(1));
      expect(c.list().single.headers['Cookie'], 'req=1');
      expect(c.list().single, same(sniffed));
    });

    test('DOM 走査は URL で重複を除き、メディアでないものは捨て、画像は取り込む', () {
      final c = SniffCollector();
      c.addFromPage(mp4, {});
      c.addFromPage(mp4, {});
      c.addFromPage('https://x/a.mp3', {});
      c.addFromPage('https://x/style.css', {});
      c.addFromPage('https://x/p.jpg', {});
      expect(c.list().map((e) => e.url).toSet(),
          {mp4, 'https://x/a.mp3', 'https://x/p.jpg'});
    });

    test('clear で前のページの検出を空にする', () {
      final c = SniffCollector()..addFromPage(mp4, {});
      c.clear();
      expect(c.list(), isEmpty);
    });

    test('通信で拾った検出にも、あとで分かった表紙・タイトル・実コマが足される', () {
      final c = SniffCollector();
      c.capture(mp4, {'Cookie': 'req=1'});
      c.addFromPage(mp4, {'User-Agent': 'UA'},
          poster: 'https://cdn.example.com/cover.jpg',
          label: '動画の表題',
          frame: 'data:image/jpeg;base64,AAAA');
      final item = c.list().single;
      // 通信由来のヘッダはそのまま残す
      expect(item.headers['Cookie'], 'req=1');
      expect(item.poster, 'https://cdn.example.com/cover.jpg');
      expect(item.label, '動画の表題');
      expect(item.frame, 'data:image/jpeg;base64,AAAA');
    });

    test('すでに持っている表紙・タイトル・実コマはあとの通知で上書きしない', () {
      final c = SniffCollector();
      c.addFromPage(mp4, {},
          poster: 'https://cdn.example.com/cover.jpg',
          label: '動画の表題',
          frame: 'data:image/jpeg;base64,AAAA');
      c.addFromPage(mp4, {},
          poster: 'https://cdn.example.com/other.jpg',
          label: '別の表題',
          frame: 'data:image/jpeg;base64,BBBB');
      expect(c.list().single.poster, 'https://cdn.example.com/cover.jpg');
      expect(c.list().single.label, '動画の表題');
      expect(c.list().single.frame, 'data:image/jpeg;base64,AAAA');
    });

    test('DOM 走査だけの検出にも表紙・タイトルを持つ', () {
      final c = SniffCollector();
      c.addFromPage(mp4, {}, poster: 'p.jpg', label: '表題');
      expect(c.list().single.poster, 'p.jpg');
      expect(c.list().single.label, '表題');
    });
  });

  group('名前と MIME', () {
    test('一覧に出る拡張子ならそのまま、無ければ MIME から借りる', () {
      expect(normalizeUploadName('clip.mp4', 'video/mp4'), 'clip.mp4');
      expect(normalizeUploadName('clip', 'video/mp4'), 'clip.mp4');
      expect(normalizeUploadName('clip.bin', 'image/png'), 'clip.png');
      expect(normalizeUploadName('a/b/c.MOV?x=1#y', 'video/quicktime'),
          'c.MOV');
      expect(normalizeUploadName('', 'video/webm'), 'upload.webm');
      // 借りられる MIME が無ければ拡張子なしのまま（上げても一覧に出ない）
      expect(hasListedExtension(normalizeUploadName('song.mp3', 'audio/mpeg')),
          isFalse);
    });

    test('同名キーの候補は (2)(3) を拡張子の前に付ける', () {
      expect(suffixedName('a.mp4', 1), 'a.mp4');
      expect(suffixedName('a.mp4', 2), 'a (2).mp4');
      expect(suffixedName('noext', 3), 'noext (3)');
    });

    test('HLS は ts の名前と MIME で置く。音声は一覧に出ないので保存不可', () {
      final hls = webUploadTarget(
          const DetectedItem('https://x.test/v/master.m3u8?t=1', DetectedKind.hls));
      expect(hls.name, 'master.ts');
      expect(hls.mime, 'video/mp2t');
      expect(
          isWebSavable(const DetectedItem(
              'https://x.test/a.mp4', DetectedKind.video)),
          isTrue);
      expect(
          isWebSavable(const DetectedItem(
              'https://x.test/a.mp3', DetectedKind.audio)),
          isFalse);
    });
  });

  group('取り込み画面の部品', () {
    test('保存を止める理由は保存先の状態で決まる', () {
      expect(
          saveBlockFor(libFound: false, hasConnection: true, libReadOnly: false),
          SaveBlock.noLibrary);
      expect(
          saveBlockFor(libFound: false, hasConnection: false, libReadOnly: false),
          SaveBlock.notConnected);
      expect(
          saveBlockFor(libFound: true, hasConnection: true, libReadOnly: true),
          SaveBlock.readOnly);
      expect(
          saveBlockFor(libFound: true, hasConnection: true, libReadOnly: false),
          isNull);
    });

    test('サイズ表記', () {
      expect(fmtSize(0), '0 KB');
      expect(fmtSize(1499), '1 KB');
      expect(fmtSize(1_500_000), '1.5 MB');
      expect(fmtSize(2_999_999_999), '2.9 GB');
    });

    test('履歴の日時は月/日 時:分', () {
      final t = DateTime(2026, 3, 4, 5, 6).millisecondsSinceEpoch;
      expect(fmtHist(t), '03/04 05:06');
    });

    test('転送の要約', () {
      WebTransferTask t(WebTaskStatus s) => WebTransferTask(
          id: 'x', lib: 'l', url: 'u', headers: const {}, hls: false, name: 'n', mime: 'm')
        ..status = s;
      expect(transfersSummary([t(WebTaskStatus.fetching), t(WebTaskStatus.error)]),
          '転送中 1件・失敗 1件');
      expect(transfersSummary([t(WebTaskStatus.error)]), '失敗 1件');
      expect(transfersSummary([t(WebTaskStatus.done)]), '転送完了 1件');
    });
  });

  group('履歴', () {
    WebHistoryEntry e(int i) => WebHistoryEntry(
        name: 'n$i', key: 'k$i', url: 'u', mime: 'video/mp4', size: i, at: i);

    test('新しい順で、200件を超えたら古いものから落とす', () async {
      String? stored;
      final h = WebHistoryStore(
          read: () async => stored, write: (v) async => stored = v);
      await Future.wait([for (var i = 0; i < 205; i++) h.add(e(i))]);
      final list = await h.list();
      expect(list, hasLength(200));
      expect(list.first.name, 'n204');
      expect(list.last.name, 'n5');
    });

    test('壊れた保存値は空として扱う', () async {
      final h = WebHistoryStore(read: () async => '{oops', write: (_) async {});
      expect(await h.list(), isEmpty);
      final h2 = WebHistoryStore(read: () async => '{"a":1}', write: (_) async {});
      expect(await h2.list(), isEmpty);
    });
  });

  group('URL の決まり', () {
    test('スキームを省いた入力は https、http/https はそのまま', () {
      expect(normalizeBrowserInput(' example.com/video '),
          'https://example.com/video');
      expect(normalizeBrowserInput('http://a.example/x'), 'http://a.example/x');
      expect(normalizeBrowserInput('https://a.example/'), 'https://a.example/');
    });

    test('端末内や他アプリへ抜けるスキームは開かない', () {
      for (final bad in [
        'file:///sdcard/a.mp4',
        'content://media/external/1',
        'intent://scan/#Intent;scheme=zxing;end',
        'javascript:alert(1)',
        'data:text/html,<b>x</b>',
        'ftp://a.example/x.mp4',
        '',
        '   ',
      ]) {
        expect(normalizeBrowserInput(bad), isNull, reason: bad);
      }
      expect(isWebUrl('file:///a.mp4'), isFalse);
      expect(isWebUrl('https://a.example/a.mp4'), isTrue);
    });

    test('ページが送ってきた http/https 以外の URL は検出に入れない', () {
      final c = SniffCollector();
      expect(c.capture('file:///sdcard/a.mp4', null), isNull);
      expect(c.addFromPage('content://media/1.mp4', const {}), isNull);
      expect(c.addFromPage('https://a.example/1.mp4', const {}), isNotNull);
      expect(c.list(), hasLength(1));
    });

    test('1ページで抱える検出には上限がある', () {
      final c = SniffCollector();
      for (var i = 0; i < SniffCollector.maxItems + 50; i++) {
        c.addFromPage('https://a.example/$i.mp4', const {});
      }
      expect(c.list(), hasLength(SniffCollector.maxItems));
      // 既に持っている URL は上限に達していても受け付ける（重複除去のため）
      expect(c.addFromPage('https://a.example/0.mp4', const {}), isNotNull);
    });
  });
}
