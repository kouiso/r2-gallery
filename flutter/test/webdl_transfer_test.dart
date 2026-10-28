import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/transfer/transfer_queue.dart' show LedgerStore;
import 'package:r2_gallery/src/webdl/detected.dart';
import 'package:r2_gallery/src/webdl/web_fetcher.dart';
import 'package:r2_gallery/src/webdl/web_history.dart';
import 'package:r2_gallery/src/webdl/web_transfer.dart';

/// 取得元サイト + worker を1つのローカルサーバーで真似る。
/// 本物の Dio / HttpClient で往復させるので、Range・ストリーム・multipart の実際の動きを見られる。
class FakeServer {
  late final HttpServer server;
  String get base => 'http://127.0.0.1:${server.port}';

  // 取得元
  final Map<String, Uint8List> media = {};
  final Map<String, String> text = {};
  final Set<String> ignoreRange = {};
  // 末尾より先の Range に、仕様どおり 416 を返す取得元
  final Set<String> strictRange = {};
  final Map<String, int> failStatus = {};
  // 最初のリクエストだけ途中で切る位置
  final Map<String, int> dropAfter = {};
  final Map<String, int> shortBodies = {};
  final Set<String> slow = {};
  final List<HttpHeaders> mediaRequests = [];
  final Map<String, List<String?>> rangesSeen = {};
  // 名前 → 302 で飛ばす先
  final Map<String, String> redirects = {};

  // worker
  final Map<String, Uint8List> objects = {};
  final Map<String, Uint8List> thumbs = {};
  final Set<String> existingKeys = {};
  final List<int> partSizes = [];
  final Map<String, List<Uint8List>> _parts = {};
  int multipartCreates = 0;
  int multipartAborts = 0;
  int objectPuts = 0;
  bool wrongReceipt = false;
  int folderListings = 0;
  bool failFolders = false;
  int? failPart;
  Completer<void>? holdPut;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) => _handle(r).catchError((_) {}));
  }

  Future<void> stop() => server.close(force: true);

  Future<Uint8List> _body(HttpRequest r) async {
    final b = BytesBuilder(copy: false);
    await for (final c in r) {
      b.add(c);
    }
    return b.takeBytes();
  }

  Future<void> _handle(HttpRequest r) async {
    final path = r.uri.path;
    if (path.startsWith('/m/')) return _media(r, path.substring(3));
    if (path.startsWith('/v1/')) return _worker(r);
    r.response.statusCode = 404;
    await r.response.close();
  }

  Future<void> _media(HttpRequest r, String name) async {
    mediaRequests.add(r.headers);
    final to = redirects[name];
    if (to != null) {
      r.response.statusCode = 302;
      r.response.headers.set('location', to);
      await r.response.close();
      return;
    }
    final range = r.headers.value('range');
    (rangesSeen[name] ??= []).add(range);
    final res = r.response;
    final fail = failStatus[name];
    if (fail != null) {
      res.statusCode = fail;
      await res.close();
      return;
    }
    final t = text[name];
    if (t != null) {
      res.write(t);
      await res.close();
      return;
    }
    final data = media[name] ?? objects[name];
    if (data == null) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    var start = 0;
    if (range != null && !ignoreRange.contains(name)) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (strictRange.contains(name) && start >= data.length) {
        res.statusCode = 416;
        res.headers.set('Content-Range', 'bytes */${data.length}');
        await res.close();
        return;
      }
      res.statusCode = 206;
      res.headers.set('Content-Range', 'bytes $start-${data.length - 1}/${data.length}');
    }
    final body = Uint8List.sublistView(data, start, shortBodies[name]);
    final drop = dropAfter.remove(name);
    if (drop != null) {
      // ヘッダだけ正しく出して、本文の途中で接続を切る
      final sock = await res.detachSocket(writeHeaders: false);
      final status = start > 0 ? '206 Partial Content' : '200 OK';
      final extra = start > 0
          ? 'Content-Range: bytes $start-${data.length - 1}/${data.length}\r\n'
          : '';
      sock.write('HTTP/1.1 $status\r\n${extra}Content-Length: ${body.length}\r\n\r\n');
      sock.add(body.sublist(0, drop));
      await sock.flush();
      sock.destroy();
      return;
    }
    res.contentLength = body.length;
    if (slow.contains(name)) {
      for (var i = 0; i < body.length; i += 1024) {
        res.add(body.sublist(i, i + 1024 > body.length ? body.length : i + 1024));
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } else {
      res.add(body);
    }
    await res.close();
  }

  Future<void> _worker(HttpRequest r) async {
    final res = r.response;
    final p = r.uri.path;
    final key = r.uri.queryParameters['key'];
    if (r.headers.value('authorization') != 'Bearer tok') {
      res.statusCode = 401;
      await res.close();
      return;
    }
    Future<void> json(Object o, [int code = 200]) async {
      res.statusCode = code;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(o));
      await res.close();
    }

    if (r.method == 'GET' && p.endsWith('/folders')) {
      folderListings++;
      if (failFolders) {
        res.statusCode = 500;
        await res.close();
        return;
      }
      // worker と同じく、接頭辞に当たるキーを大きさ付きで返す（ゴミ箱に移したものは含めない）
      final prefix = r.uri.queryParameters['prefix'] ?? '';
      return json({
        'prefix': prefix,
        'folders': <String>[],
        'items': [
          for (final e in objects.entries)
            if (e.key.startsWith(prefix))
              {'key': e.key, 'type': 'video', 'url': '$base/m/${e.key}', 'size': e.value.length},
        ],
        'cursor': null,
      });
    }
    if (r.method == 'PUT' && p.endsWith('/thumb')) {
      thumbs[key!] = await _body(r);
      return json({});
    }
    if (r.method == 'PUT' && p.endsWith('/objects')) {
      objectPuts++;
      final body = await _body(r);
      if (holdPut != null) await holdPut!.future;
      if (existingKeys.contains(key)) return json({'error': 'exists'}, 409);
      objects[key!] = body;
      existingKeys.add(key);
      return json({'key': key, 'size': wrongReceipt ? body.length + 1 : body.length}, 201);
    }
    if (p.endsWith('/objects/multipart') && r.method == 'POST') {
      multipartCreates++;
      final b = jsonDecode(utf8.decode(await _body(r))) as Map<String, dynamic>;
      if (existingKeys.contains(b['key'])) return json({'error': 'exists'}, 409);
      _parts['u1'] = [];
      return json({'uploadId': 'u1'});
    }
    if (p.endsWith('/objects/multipart/part') && r.method == 'PUT') {
      final body = await _body(r);
      if (r.uri.queryParameters['part'] == '$failPart') {
        res.statusCode = 500;
        await res.close();
        return;
      }
      partSizes.add(body.length);
      _parts[r.uri.queryParameters['uploadId']!]!.add(body);
      final n = int.parse(r.uri.queryParameters['part']!);
      return json({'partNumber': n, 'etag': 'e$n'});
    }
    if (p.endsWith('/objects/multipart/complete')) {
      final b = jsonDecode(utf8.decode(await _body(r))) as Map<String, dynamic>;
      final all = BytesBuilder();
      for (final part in _parts[b['uploadId']]!) {
        all.add(part);
      }
      objects[b['key'] as String] = all.takeBytes();
      existingKeys.add(b['key'] as String);
      final size = objects[b['key']]!.length;
      return json({'key': b['key'], 'size': wrongReceipt ? size + 1 : size}, 201);
    }
    if (p.endsWith('/objects/multipart/abort')) {
      multipartAborts++;
      await _body(r);
      return json({});
    }
    res.statusCode = 404;
    await res.close();
  }
}

/// 端末の保存値の代わり。アプリを消して開き直したことを、同じ置き場を読む別のキューで真似る。
class MemLedger implements LedgerStore {
  String? value;
  bool failRead = false;
  bool failWrites = false;
  bool failEmptyWrites = false;
  int writes = 0;
  @override
  Future<String?> read() async {
    if (failRead) throw Exception('secure storage busy');
    return value;
  }

  @override
  Future<void> write(String json) async {
    writes++;
    if (failWrites || (failEmptyWrites && (jsonDecode(json) as List).isEmpty)) {
      throw Exception('secure storage write failed');
    }
    value = json;
  }

  List<dynamic> get rows => value == null ? const [] : jsonDecode(value!) as List;
}

Uint8List _bytes(int n, [int seed = 7]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

void main() {
  late FakeServer s;
  late ApiClient api;
  late Directory tmp;
  late WebTransferQueue queue;
  late List<String> thumbMimes;
  String? historyJson;

  setUp(() async {
    s = FakeServer();
    await s.start();
    api = ApiClient()..setConnection(Connection(s.base, 'tok'));
    // 「r2g-web-」で始まる一時フォルダはアプリが前の版の置き場として消すので、並んで走る別のテストに消されない名前にする
    tmp = await Directory.systemTemp.createTemp('r2g-webq-test-');
    thumbMimes = [];
    historyJson = null;
    queue = WebTransferQueue(
      api: api,
      stageDir: tmp,
      retryDelay: Duration.zero,
      history: WebHistoryStore(
          read: () async => historyJson, write: (v) async => historyJson = v),
      makeThumb: (file, mime) async {
        thumbMimes.add(mime);
        return Uint8List.fromList([1, 2, 3]);
      },
    );
  });

  tearDown(() async {
    queue.dispose();
    await s.stop();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  DetectedItem video(String name, {Map<String, String> headers = const {}}) =>
      DetectedItem('${s.base}/m/$name', DetectedKind.video, headers);

  Future<void> run() => queue.idle().timeout(const Duration(seconds: 20));

  List<FileSystemEntity> staged() => tmp.listSync();

  group('ApiClient.putFile', () {
    test('小さいファイルは一括 PUT', () async {
      final f = File('${tmp.path}/small.mp4')..writeAsBytesSync(_bytes(1000));
      await api.putFile('lib', 'a/small.mp4', f, 'video/mp4');
      expect(s.objects['a/small.mp4'], _bytes(1000));
      expect(s.multipartCreates, 0);
    });

    test('大きいファイルは8MBずつ読んで multipart に流す（全体をメモリに載せない）', () async {
      const size = 20 * 1024 * 1024 + 123;
      final data = _bytes(size);
      final f = File('${tmp.path}/big.mp4')..writeAsBytesSync(data);
      final seen = <int>[];
      await api.putFile('lib', 'big.mp4', f, 'video/mp4',
          onProgress: (sent, total) => seen.add(sent));
      expect(s.multipartCreates, 1);
      expect(s.partSizes, [8 * 1024 * 1024, 8 * 1024 * 1024, 4 * 1024 * 1024 + 123]);
      expect(s.objects['big.mp4'], data);
      expect(seen.last, size);
    });

    test('パートの途中で失敗したら multipart を中止して例外を返す', () async {
      final f = File('${tmp.path}/big.mp4')
        ..writeAsBytesSync(_bytes(17 * 1024 * 1024));
      s.failPart = 2;
      await expectLater(
          api.putFile('lib', 'big.mp4', f, 'video/mp4'), throwsA(isA<ApiError>()));
      expect(s.multipartAborts, 1);
      expect(s.objects, isEmpty);
    });
  });

  group('WebTransferQueue', () {
    test('取得→アップロード→サムネ→履歴まで通り、一時ファイルは消える', () async {
      final data = _bytes(300 * 1024);
      s.media['clip.mp4'] = data;
      final added = queue.enqueue('lib', [video('clip.mp4')]);
      expect(added.single.name, 'clip.mp4');
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(t.key, 'downloads/clip.mp4');
      expect(s.objects['downloads/clip.mp4'], data);
      expect(s.thumbs['downloads/clip.mp4'], [1, 2, 3]);
      expect(thumbMimes, ['video/mp4']);
      expect(staged(), isEmpty);
      final h = await queue.history.list();
      expect(h.single.name, 'clip.mp4');
      expect(h.single.key, 'downloads/clip.mp4');
      expect(h.single.size, data.length);
    });

    group('取り込み済みの見分け（#162）', () {
      test('同じ保存先へ同じ URL から取り込み済みで、R2 に残っていれば記録を返す', () async {
        s.media['clip.mp4'] = _bytes(4000);
        queue.enqueue('lib', [video('clip.mp4')]);
        await run();
        final dup = await queue.findDuplicate('lib', video('clip.mp4').url);
        expect(dup?.key, 'downloads/clip.mp4');
        expect(dup?.lib, 'lib');
      });

      test('URL が違えば、名前と大きさが同じ別の動画でも止めない', () async {
        s.media['clip.mp4'] = _bytes(4000);
        s.media['other/clip.mp4'] = _bytes(4000, 9);
        queue.enqueue('lib', [video('clip.mp4')]);
        await run();
        expect(await queue.findDuplicate('lib', video('other/clip.mp4').url), isNull);
      });

      test('R2 から消した（ゴミ箱へ移した）動画は「既にあります」にしない', () async {
        s.media['clip.mp4'] = _bytes(4000);
        queue.enqueue('lib', [video('clip.mp4')]);
        await run();
        s.objects.remove('downloads/clip.mp4');
        s.existingKeys.remove('downloads/clip.mp4');
        expect(await queue.findDuplicate('lib', video('clip.mp4').url), isNull);
      });

      test('消した後に同じ名前の別ファイルが置かれていたら止めない', () async {
        s.media['clip.mp4'] = _bytes(4000);
        queue.enqueue('lib', [video('clip.mp4')]);
        await run();
        s.objects['downloads/clip.mp4'] = _bytes(1234);
        expect(await queue.findDuplicate('lib', video('clip.mp4').url), isNull);
      });

      test('別のライブラリへの取り込みは、この保存先の重複にしない', () async {
        s.media['clip.mp4'] = _bytes(4000);
        queue.enqueue('libA', [video('clip.mp4')]);
        await run();
        expect(await queue.findDuplicate('libB', video('clip.mp4').url), isNull);
      });

      test('確かめられない時（一覧の取得に失敗）は止めず、今まで通り取り込ませる', () async {
        s.media['clip.mp4'] = _bytes(4000);
        queue.enqueue('lib', [video('clip.mp4')]);
        await run();
        s.failFolders = true;
        expect(await queue.findDuplicate('lib', video('clip.mp4').url), isNull);
      });

      test('保存先を持たない古い履歴は、キーと大きさが両方合う時だけ重複とみなす', () async {
        s.objects['downloads/old.mp4'] = _bytes(500);
        final url = video('old.mp4').url;
        historyJson = jsonEncode([
          {'name': 'old.mp4', 'key': 'downloads/old.mp4', 'url': url, 'mime': 'video/mp4', 'size': 500, 'at': 1},
        ]);
        expect((await queue.findDuplicate('lib', url))?.key, 'downloads/old.mp4');
        historyJson = jsonEncode([
          {'name': 'old.mp4', 'key': 'downloads/old.mp4', 'url': url, 'mime': 'video/mp4', 'size': 999, 'at': 1},
        ]);
        expect(await queue.findDuplicate('lib', url), isNull);
      });

      test('履歴に無い URL は R2 に問い合わせもしない', () async {
        expect(await queue.findDuplicate('lib', video('new.mp4').url), isNull);
        expect(s.folderListings, 0);
      });
    });

    test('ページのヘッダ（UA / Referer / Cookie）を載せて取り、Range は引き継がない', () async {
      s.media['hot.mp4'] = _bytes(5000);
      queue.enqueue('lib', [
        video('hot.mp4', headers: {
          'User-Agent': 'PageUA/1',
          'Referer': 'https://example.com/page',
          'Cookie': 'sess=abc',
          'Range': 'bytes=0-1',
          'Host': 'evil.example',
        })
      ]);
      await run();
      expect(queue.tasks.single.status, WebTaskStatus.done);
      final h = s.mediaRequests.single;
      expect(h.value('user-agent'), 'PageUA/1');
      expect(h.value('referer'), 'https://example.com/page');
      expect(h.value('cookie'), 'sess=abc');
      expect(h.value('range'), isNull);
      expect(h.value('host'), isNot('evil.example'));
      expect(s.objects['downloads/hot.mp4'], hasLength(5000));
    });

    test('同名キーが既にあれば (2)(3) と進めて上書きしない', () async {
      s.media['clip.mp4'] = _bytes(100);
      s.existingKeys.addAll(['downloads/clip.mp4', 'downloads/clip (2).mp4']);
      queue.enqueue('lib', [video('clip.mp4')]);
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(t.key, 'downloads/clip (3).mp4');
      expect(s.objects.keys, ['downloads/clip (3).mp4']);
    });

    test('一覧に出ない形式（音声）は取りに行かず理由を出す', () async {
      s.media['song.mp3'] = _bytes(100);
      queue.enqueue('lib', [
        DetectedItem('${s.base}/m/song.mp3', DetectedKind.audio),
      ]);
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.error);
      expect(t.error, contains('ギャラリーに表示できない'));
      expect(s.mediaRequests, isEmpty);
      expect(s.objects, isEmpty);
    });

    test('処理中の同じ URL は積み直さない', () async {
      s.media['clip.mp4'] = _bytes(100);
      s.holdPut = Completer<void>();
      expect(queue.enqueue('lib', [video('clip.mp4')]), hasLength(1));
      expect(queue.enqueue('lib', [video('clip.mp4')]), isEmpty);
      s.holdPut!.complete();
      await run();
      // 終わった後なら積める
      expect(queue.enqueue('lib', [video('clip.mp4')]), hasLength(1));
      await run();
    });

    test('通信が途中で切れたら Range で続きから取る', () async {
      final data = _bytes(200 * 1024);
      s.media['drop.mp4'] = data;
      s.dropAfter['drop.mp4'] = 50 * 1024;
      queue.enqueue('lib', [video('drop.mp4')]);
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(s.objects['downloads/drop.mp4'], data);
      final ranges = s.rangesSeen['drop.mp4']!;
      expect(ranges.first, isNull);
      expect(ranges.last, startsWith('bytes='));
      expect(ranges.last, isNot('bytes=0-'));
    });

    test('Range を無視するサーバーでは、部分ファイルに追記せず最初から取り直す', () async {
      final data = _bytes(200 * 1024);
      s.media['norange.mp4'] = data;
      s.ignoreRange.add('norange.mp4');
      s.dropAfter['norange.mp4'] = 50 * 1024;
      queue.enqueue('lib', [video('norange.mp4')]);
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      // 追記して重複していれば長さが合わない
      expect(s.objects['downloads/norange.mp4'], data);
    });

    test('HTTP エラーは失敗として残り、直ってからのやり直しで完了する', () async {
      s.media['gone.mp4'] = _bytes(1000);
      s.failStatus['gone.mp4'] = 403;
      queue.enqueue('lib', [video('gone.mp4')]);
      await run();
      var t = queue.tasks.single;
      expect(t.status, WebTaskStatus.error);
      expect(t.error, contains('403'));
      expect(s.objects, isEmpty);
      s.failStatus.remove('gone.mp4');
      queue.retry(t.id);
      await run();
      t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(s.objects['downloads/gone.mp4'], _bytes(1000));
    });

    test('0バイトの応答は取れたことにしない', () async {
      s.media['empty.mp4'] = Uint8List(0);
      queue.enqueue('lib', [video('empty.mp4')]);
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.error);
      expect(t.error, 'empty download');
      expect(s.objects, isEmpty);
    });

    test('アップロードが失敗しても落とした分は残り、やり直しは上げ直すだけ', () async {
      s.media['clip.mp4'] = _bytes(1000);
      api.setConnection(Connection(s.base, 'wrong'));
      queue.enqueue('lib', [video('clip.mp4')]);
      await run();
      var t = queue.tasks.single;
      expect(t.status, WebTaskStatus.error);
      expect(t.staged, isNotNull);
      final fetches = s.mediaRequests.length;
      api.setConnection(Connection(s.base, 'tok'));
      queue.retry(t.id);
      await run();
      t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(s.mediaRequests.length, fetches, reason: '取り直していない');
    });

    test('取得中に取り消すと、何も上げず一時ファイルも消える', () async {
      s.media['slow.mp4'] = _bytes(400 * 1024);
      s.slow.add('slow.mp4');
      final t = queue.enqueue('lib', [video('slow.mp4')]).single;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(t.status, WebTaskStatus.fetching);
      queue.cancel(t.id);
      await run();
      expect(t.status, WebTaskStatus.cancelled);
      expect(s.objects, isEmpty);
      expect(staged(), isEmpty);
    });

    test('取得中に一時停止すると落とした分を残し、再開は続きから取る', () async {
      final data = _bytes(400 * 1024);
      s.media['slow.mp4'] = data;
      s.slow.add('slow.mp4');
      final t = queue.enqueue('lib', [video('slow.mp4')]).single;
      for (var i = 0; i < 300 && t.loaded < 4096; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      queue.pause(t.id);
      await run();
      expect(t.status, WebTaskStatus.paused);
      expect(t.finished, isFalse);
      expect(staged(), isNotEmpty);
      // 終わった行の整理で一時停止の行は消さない
      queue.clearFinished();
      expect(queue.tasks, contains(t));

      s.slow.remove('slow.mp4');
      queue.resume(t.id);
      await run();
      expect(t.status, WebTaskStatus.done);
      expect(s.objects.values.single, data);
      expect(s.rangesSeen['slow.mp4'], [null, startsWith('bytes=')]);
    });

    test('同時に走るのは2件まで', () async {
      for (var i = 0; i < 4; i++) {
        s.media['v$i.mp4'] = _bytes(100 * 1024, i);
        s.slow.add('v$i.mp4');
      }
      queue.enqueue('lib', [for (var i = 0; i < 4; i++) video('v$i.mp4')]);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(queue.tasks.where((t) => t.status == WebTaskStatus.fetching),
          hasLength(2));
      expect(queue.tasks.where((t) => t.status == WebTaskStatus.queued),
          hasLength(2));
      await run();
      expect(queue.tasks.every((t) => t.status == WebTaskStatus.done), isTrue);
      expect(s.objects, hasLength(4));
    });

    test('大きい動画は8MBずつの multipart で上がる', () async {
      final data = _bytes(17 * 1024 * 1024);
      s.media['big.mp4'] = data;
      queue.enqueue('lib', [video('big.mp4')]);
      await Future<void>.delayed(Duration.zero);
      await queue.idle().timeout(const Duration(seconds: 60));
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(s.multipartCreates, 1);
      expect(s.partSizes.every((n) => n <= 8 * 1024 * 1024), isTrue);
      expect(s.objects['downloads/big.mp4'], data);
    }, timeout: const Timeout(Duration(seconds: 90)));

    group('HLS', () {
      void seed() {
        s.text['master.m3u8'] = '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=9000\nhigh.m3u8\n';
        s.text['high.m3u8'] = '#EXTM3U\n#EXTINF:4,\nh0.ts\n#EXTINF:4,\nh1.ts\n#EXTINF:4,\nh2.ts\n#EXT-X-ENDLIST\n';
        s.text['low.m3u8'] = '#EXTM3U\n#EXTINF:4,\nl0.ts\n#EXT-X-ENDLIST\n';
        for (var i = 0; i < 3; i++) {
          s.media['h$i.ts'] = _bytes(5000, 10 + i);
        }
        s.media['l0.ts'] = _bytes(10, 99);
      }

      DetectedItem hls(String name) =>
          DetectedItem('${s.base}/m/$name', DetectedKind.hls);

      test('最良の画質を選び、全セグメントを順に繋いだ ts を上げる', () async {
        seed();
        queue.enqueue('lib', [hls('master.m3u8')]);
        await run();
        final t = queue.tasks.single;
        expect(t.status, WebTaskStatus.done, reason: t.error);
        expect(t.key, 'downloads/master.ts');
        final expected = BytesBuilder()
          ..add(_bytes(5000, 10))
          ..add(_bytes(5000, 11))
          ..add(_bytes(5000, 12));
        expect(s.objects['downloads/master.ts'], expected.takeBytes());
        expect(s.rangesSeen.containsKey('l0.ts'), isFalse);
        expect(thumbMimes, ['video/mp2t']);
      });

      test('暗号化された HLS は壊れた動画を作らず失敗にする', () async {
        s.text['enc.m3u8'] =
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXTINF:4,\ne0.ts\n';
        s.media['e0.ts'] = _bytes(10);
        queue.enqueue('lib', [hls('enc.m3u8')]);
        await run();
        final t = queue.tasks.single;
        expect(t.status, WebTaskStatus.error);
        expect(t.error, contains('暗号化'));
        expect(s.objects, isEmpty);
      });

      test('途中のセグメントで失敗しても、やり直しは続きのセグメントから取る', () async {
        seed();
        s.failStatus['h1.ts'] = 500;
        queue.enqueue('lib', [hls('master.m3u8')]);
        await run();
        var t = queue.tasks.single;
        expect(t.status, WebTaskStatus.error);
        expect(t.hlsSeg, 1);
        s.failStatus.remove('h1.ts');
        queue.retry(t.id);
        await run();
        t = queue.tasks.single;
        expect(t.status, WebTaskStatus.done, reason: t.error);
        // 先頭セグメントは取り直していない
        expect(s.rangesSeen['h0.ts'], hasLength(1));
        final expected = BytesBuilder()
          ..add(_bytes(5000, 10))
          ..add(_bytes(5000, 11))
          ..add(_bytes(5000, 12));
        expect(s.objects['downloads/master.ts'], expected.takeBytes());
      });
    });
  });

  // 閲覧ページは信用できん。取得で Cookie を第三者へ漏らさず、端末内へ向く URL は取らない
  group('取得の安全策', () {
    // 同じ待ち受けを別のホスト名で指す（Cookie はポートでなくホスト名で分かれる）
    String other(String name) => 'http://localhost:${s.server.port}/m/$name';

    test('別ホストへのリダイレクトには、検出元の Cookie を持ち越さない', () async {
      s.media['clip.mp4'] = _bytes(2000);
      s.redirects['go.mp4'] = other('clip.mp4');
      queue.enqueue('lib', [
        video('go.mp4', headers: {'Cookie': 'sess=abc', 'Referer': 'https://p.example/'}),
      ]);
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(s.mediaRequests, hasLength(2));
      expect(s.mediaRequests[0].value('cookie'), 'sess=abc');
      expect(s.mediaRequests[1].host, 'localhost');
      expect(s.mediaRequests[1].value('cookie'), isNull);
      expect(s.objects['downloads/go.mp4'], hasLength(2000));
    });

    test('Cookie は送り先ごとにブラウザから引き直す', () async {
      final looked = <String>[];
      final q = WebTransferQueue(
        api: api,
        stageDir: await tmp.createTemp('q2-'),
        retryDelay: Duration.zero,
        history: WebHistoryStore(read: () async => null, write: (_) async {}),
        fetcher: WebFetcher(cookieFor: (u) async {
          looked.add(Uri.parse(u).host);
          return Uri.parse(u).host == 'localhost' ? 'cdn=1' : null;
        }),
      );
      addTearDown(q.dispose);
      s.media['clip.mp4'] = _bytes(1000);
      s.redirects['go.mp4'] = other('clip.mp4');
      q.enqueue('lib', [video('go.mp4', headers: {'Cookie': 'sess=abc'})]);
      await q.idle().timeout(const Duration(seconds: 20));
      expect(q.tasks.single.status, WebTaskStatus.done, reason: q.tasks.single.error);
      expect(looked, ['127.0.0.1', 'localhost']);
      expect(s.mediaRequests[0].value('cookie'), 'sess=abc');
      expect(s.mediaRequests[1].value('cookie'), 'cdn=1');
    });

    test('http/https 以外へのリダイレクトはたどらず失敗にする', () async {
      s.redirects['bad.mp4'] = 'file:///data/data/app.r2gallery/shared_prefs/x.mp4';
      queue.enqueue('lib', [video('bad.mp4')]);
      await run();
      final t = queue.tasks.single;
      expect(t.status, WebTaskStatus.error);
      expect(t.error, contains('http/https'));
      expect(s.objects, isEmpty);
    });

    test('http/https 以外の URL は積んでも取りに行かない', () async {
      queue.enqueue('lib', const [
        DetectedItem('file:///sdcard/DCIM/a.mp4', DetectedKind.video),
        DetectedItem('content://media/external/video/1.mp4', DetectedKind.video),
      ]);
      await run();
      expect(queue.tasks.map((t) => t.status),
          everyElement(WebTaskStatus.error));
      expect(queue.tasks.first.error, contains('http/https'));
      queue.retry(queue.tasks.first.id);
      await run();
      expect(queue.tasks.first.status, WebTaskStatus.error);
      expect(s.mediaRequests, isEmpty);
    });
  });

  group('アプリを消しても取り込みを失わない（#163）', () {
    late MemLedger ledger;
    late Directory stage;
    final opened = <WebTransferQueue>[];

    late Directory root;

    setUp(() async {
      ledger = MemLedger();
      // 「r2g-web-」で始まる一時フォルダは前の版の置き場として起動時に消されるので、別の名前に置く
      root = await Directory.systemTemp.createTemp('r2g-ledger-test-');
      stage = Directory('${root.path}/stage');
      historyJson = null;
    });

    tearDown(() async {
      for (final q in opened) {
        q.dispose();
      }
      opened.clear();
      if (await root.exists()) await root.delete(recursive: true);
    });

    // 開き直すたびに同じ台帳と置き場を読む新しいキューを作る（前のキューは消されたものとして捨てる）
    WebTransferQueue open() {
      final q = WebTransferQueue(
        api: api,
        retryDelay: Duration.zero,
        ledger: ledger,
        persistentStageDir: () async => stage,
        history: WebHistoryStore(
            read: () async => historyJson, write: (v) async => historyJson = v),
      );
      opened.add(q);
      return q;
    }

    Future<void> settle(WebTransferQueue q) async {
      await q.idle().timeout(const Duration(seconds: 20));
      await q.ledgerWritten().timeout(const Duration(seconds: 20));
    }

    Map<String, dynamic> row({
      required String url,
      String name = 'clip.mp4',
      String id = 'wold_1',
      bool hls = false,
      String status = 'uploading',
      bool fetched = true,
      String? pendingKey,
      int keyAttempt = 0,
      int hlsSeg = 0,
      int hlsBytes = 0,
      String? hlsVariant,
      String? error,
    }) =>
        {
          'id': id,
          'lib': 'lib',
          'url': url,
          'headers': <String, String>{},
          'hls': hls,
          'name': name,
          'mime': hls ? 'video/mp2t' : 'video/mp4',
          'status': status,
          'error': ?error,
          'size': 0,
          'hlsSeg': hlsSeg,
          'hlsBytes': hlsBytes,
          'hlsTotal': 0,
          'hlsVariant': ?hlsVariant,
          'pendingKey': ?pendingKey,
          'keyAttempt': keyAttempt,
          'fetched': fetched,
        };

    test('取得の途中で消されても、次の起動で続きから取って1つだけ上げる', () async {
      final data = _bytes(400 * 1024);
      s.media['slow.mp4'] = data;
      s.slow.add('slow.mp4');
      final first = open();
      final t = first.enqueue('lib', [video('slow.mp4')]).single;
      for (var i = 0; i < 300 && t.loaded < 8192; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(ledger.rows.single['status'], 'fetching');
      // アプリが消えた（キューごと捨てられた）
      first.dispose();
      opened.remove(first);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final partial = stage.listSync().whereType<File>().single.lengthSync();
      expect(partial, greaterThan(0));

      s.slow.remove('slow.mp4');
      final again = open();
      await again.restore();
      await settle(again);
      final r = again.tasks.single;
      expect(r.status, WebTaskStatus.done, reason: r.error);
      expect(s.objects.keys, ['downloads/slow.mp4']);
      expect(s.objects['downloads/slow.mp4'], data);
      // 2回目は落とせた所から Range で取っている
      expect(s.rangesSeen['slow.mp4']!.last, 'bytes=$partial-');
      expect(ledger.rows, isEmpty);
      expect(stage.listSync(), isEmpty);
    });

    test('取り終えた印を書く前に消されていたら、416 で止まらず取り直して1つだけ上げる', () async {
      final data = _bytes(3000);
      s.media['done.mp4'] = data;
      s.strictRange.add('done.mp4');
      await stage.create(recursive: true);
      // 全部落とし終えたが、台帳の fetched はまだ false のまま消された
      File('${stage.path}/wold_1.mp4').writeAsBytesSync(data);
      ledger.value = jsonEncode([
        row(url: video('done.mp4').url, name: 'done.mp4', status: 'fetching', fetched: false)
      ]);
      final q = open();
      await q.restore();
      await settle(q);
      final r = q.tasks.single;
      expect(r.status, WebTaskStatus.done, reason: r.error);
      expect(s.objects.keys, ['downloads/done.mp4']);
      expect(s.objects['downloads/done.mp4'], data);
      expect(s.rangesSeen['done.mp4'], ['bytes=3000-', null]);
    });

    test('送り終えた直後に消されていたら、送り直さず完了にする（name (2) を作らない）', () async {
      final data = _bytes(3000);
      final url = video('clip.mp4').url;
      await stage.create(recursive: true);
      File('${stage.path}/wold_1.mp4').writeAsBytesSync(data);
      s.objects['downloads/clip.mp4'] = data;
      s.existingKeys.add('downloads/clip.mp4');
      ledger.value = jsonEncode(
          [row(url: url, pendingKey: 'downloads/clip.mp4', keyAttempt: 1)]);
      final q = open();
      await q.restore();
      await settle(q);
      final t = q.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(t.key, 'downloads/clip.mp4');
      expect(s.objects.keys, ['downloads/clip.mp4']);
      expect((await q.history.list()).single.key, 'downloads/clip.mp4');
      expect(s.rangesSeen['downloads/clip.mp4'], [null]);
    });

    test('送りかけで消され、送り先にまだ無ければ同じ名前で送る', () async {
      final data = _bytes(3000);
      await stage.create(recursive: true);
      File('${stage.path}/wold_1.mp4').writeAsBytesSync(data);
      ledger.value = jsonEncode([
        row(url: video('clip.mp4').url, pendingKey: 'downloads/clip.mp4', keyAttempt: 1)
      ]);
      final q = open();
      await q.restore();
      await settle(q);
      expect(q.tasks.single.status, WebTaskStatus.done, reason: q.tasks.single.error);
      expect(s.objects.keys, ['downloads/clip.mp4']);
      expect(s.objects['downloads/clip.mp4'], data);
    });

    test('送り先に大きさの違う別ファイルがあれば、自分のものとみなさず次の名前で送る', () async {
      final data = _bytes(3000);
      await stage.create(recursive: true);
      File('${stage.path}/wold_1.mp4').writeAsBytesSync(data);
      s.objects['downloads/clip.mp4'] = _bytes(10);
      s.existingKeys.add('downloads/clip.mp4');
      ledger.value = jsonEncode([
        row(url: video('clip.mp4').url, pendingKey: 'downloads/clip.mp4', keyAttempt: 1)
      ]);
      final q = open();
      await q.restore();
      await settle(q);
      expect(q.tasks.single.key, 'downloads/clip (2).mp4');
      expect(s.objects['downloads/clip (2).mp4'], data);
      expect(s.objects['downloads/clip.mp4'], _bytes(10));
    });

    test('同じサイズの別ファイルを復旧済みと誤認せず、自分のデータを保存する', () async {
      final data = _bytes(3000, 7);
      final other = _bytes(3000, 11);
      await stage.create(recursive: true);
      File('${stage.path}/wold_1.mp4').writeAsBytesSync(data);
      // 送信前の台帳保存後に停止し、別の端末が同名・同サイズの別ファイルを置いた。
      s.objects['downloads/clip.mp4'] = other;
      s.existingKeys.add('downloads/clip.mp4');
      ledger.value = jsonEncode([
        row(url: video('clip.mp4').url, pendingKey: 'downloads/clip.mp4', keyAttempt: 1)
      ]);
      final q = open();
      await q.restore();
      await settle(q);
      expect(q.tasks.single.key, 'downloads/clip (2).mp4');
      expect(s.objects['downloads/clip (2).mp4'], data);
      expect(s.objects['downloads/clip.mp4'], other);
    });

    for (final failure in ['503', '途中切断', '短い応答']) {
      test('復旧の安全性: 内容照合が$failureなら原本と台帳を残し再試行できる', () async {
        final data = _bytes(3000);
        await stage.create(recursive: true);
        final source = File('${stage.path}/wold_1.mp4')..writeAsBytesSync(data);
        s.objects['downloads/clip.mp4'] = data;
        s.existingKeys.add('downloads/clip.mp4');
        if (failure == '途中切断') {
          s.dropAfter['downloads/clip.mp4'] = 1500;
        } else if (failure == '短い応答') {
          s.shortBodies['downloads/clip.mp4'] = 1500;
        } else {
          s.failStatus['downloads/clip.mp4'] = 503;
        }
        ledger.value = jsonEncode([
          row(url: video('clip.mp4').url, pendingKey: 'downloads/clip.mp4', keyAttempt: 1)
        ]);
        final q = open();
        await q.restore();
        await settle(q);
        expect(q.tasks.single.status, WebTaskStatus.error);
        expect(q.tasks.single.error, isNotEmpty);
        expect(source.readAsBytesSync(), data);
        expect(ledger.rows.single['id'], 'wold_1');
        expect(await q.history.list(), isEmpty);
        expect(s.objectPuts, 0);

        s.failStatus.clear();
        s.shortBodies.clear();
        q.retry(q.tasks.single.id);
        await settle(q);
        expect(q.tasks.single.status, WebTaskStatus.done);
        expect(s.objectPuts, 0);
        expect(ledger.rows, isEmpty);
        expect(source.existsSync(), isFalse);
        expect(s.objects.keys, ['downloads/clip.mp4']);
      });
    }

    test('復旧の安全性: 大容量の送信済み動画も内容を照合し二重に送らない', () async {
      final data = _bytes(9 * 1024 * 1024);
      await stage.create(recursive: true);
      File('${stage.path}/wold_1.mp4').writeAsBytesSync(data);
      s.objects['downloads/clip.mp4'] = data;
      s.existingKeys.add('downloads/clip.mp4');
      ledger.value = jsonEncode([
        row(url: video('clip.mp4').url, pendingKey: 'downloads/clip.mp4', keyAttempt: 1)
      ]);
      final q = open();
      await q.restore();
      await settle(q);
      expect(q.tasks.single.status, WebTaskStatus.done);
      expect(s.objects.keys, ['downloads/clip.mp4']);
      expect(s.multipartCreates, 0);
      expect(s.objectPuts, 0);
      expect(s.rangesSeen['downloads/clip.mp4'], [null]);
      expect(ledger.rows, isEmpty);
      expect(stage.listSync(), isEmpty);
    });

    for (final size in [3000, 9 * 1024 * 1024]) {
      test('復旧の安全性: ${size > ApiClient.multipartThreshold ? 'multipart' : '単発PUT'}の保存結果が不正なら完了にせず原本と台帳を残す', () async {
        final data = _bytes(size);
        await stage.create(recursive: true);
        final source = File('${stage.path}/wold_1.mp4')..writeAsBytesSync(data);
        ledger.value = jsonEncode([row(url: video('clip.mp4').url)]);
        s.wrongReceipt = true;
        final q = open();
        await q.restore();
        await settle(q);
        expect(q.tasks.single.status, WebTaskStatus.error);
        expect(q.tasks.single.error, contains('アップロード結果を確認できません'));
        expect(source.readAsBytesSync(), data);
        expect(ledger.rows.single['id'], 'wold_1');
        expect(await q.history.list(), isEmpty);

        final uploads = s.objectPuts + s.multipartCreates;
        s.wrongReceipt = false;
        q.retry(q.tasks.single.id);
        await settle(q);
        expect(q.tasks.single.status, WebTaskStatus.done);
        expect(s.objectPuts + s.multipartCreates, uploads);
        expect(ledger.rows, isEmpty);
        expect(source.existsSync(), isFalse);
      });
    }

    for (final completion in [false, true]) {
      test('復旧の安全性: ${completion ? '完了' : '送信前'}の台帳書込み失敗では原本と台帳を残し再試行できる', () async {
        final data = _bytes(3000);
        await stage.create(recursive: true);
        final source = File('${stage.path}/wold_1.mp4')..writeAsBytesSync(data);
        ledger.value = jsonEncode([row(url: video('clip.mp4').url)]);
        ledger.failWrites = !completion;
        ledger.failEmptyWrites = completion;
        final q = open();
        await q.restore();
        await settle(q);
        expect(q.tasks.single.status, WebTaskStatus.error);
        expect(q.tasks.single.error, contains('転送状態を保存できません'));
        expect(source.readAsBytesSync(), data);
        expect(ledger.rows.single['id'], 'wold_1');
        expect(await q.history.list(), isEmpty);
        expect(s.objectPuts, completion ? 1 : 0);

        ledger.failWrites = false;
        ledger.failEmptyWrites = false;
        q.retry(q.tasks.single.id);
        await settle(q);
        expect(q.tasks.single.status, WebTaskStatus.done);
        expect(s.objectPuts, 1);
        expect(s.objects['downloads/clip.mp4'], data);
        expect(ledger.rows, isEmpty);
        expect(source.existsSync(), isFalse);
      });
    }

    test('取り終えたはずの一時ファイルが消えていたら、最初から取り直す', () async {
      final data = _bytes(5000);
      s.media['clip.mp4'] = data;
      ledger.value = jsonEncode([row(url: video('clip.mp4').url)]);
      final q = open();
      await q.restore();
      await settle(q);
      expect(q.tasks.single.status, WebTaskStatus.done, reason: q.tasks.single.error);
      expect(s.objects['downloads/clip.mp4'], data);
      expect(s.rangesSeen['clip.mp4'], [null]);
    });

    test('URL の期限が切れて取り直せない時は、理由を出してやり直せる行にする', () async {
      s.media['gone.mp4'] = _bytes(5000);
      s.failStatus['gone.mp4'] = 403;
      ledger.value = jsonEncode(
          [row(url: video('gone.mp4').url, name: 'gone.mp4', status: 'fetching', fetched: false)]);
      final q = open();
      await q.restore();
      await settle(q);
      final t = q.tasks.single;
      expect(t.status, WebTaskStatus.error);
      expect(t.error, contains('403'));
      // 失敗の行は台帳に残り、もう一度開いてもやり直しの手段が残る
      expect(ledger.rows.single['status'], 'error');
      s.failStatus.remove('gone.mp4');
      q.retry(t.id);
      await settle(q);
      expect(t.status, WebTaskStatus.done, reason: t.error);
    });

    test('HLS は記録した所まで切り詰めて、続きのセグメントから取る', () async {
      s.text['v.m3u8'] = '#EXTM3U\n#EXTINF:4,\na0.ts\n#EXTINF:4,\na1.ts\n#EXTINF:4,\na2.ts\n#EXT-X-ENDLIST\n';
      for (var i = 0; i < 3; i++) {
        s.media['a$i.ts'] = _bytes(4000, 20 + i);
      }
      await stage.create(recursive: true);
      // 1つ目は記録済み。2つ目は途中まで書いた所で消された（台帳には入っていない）
      File('${stage.path}/wold_1.ts')
          .writeAsBytesSync([..._bytes(4000, 20), ..._bytes(1500, 21)]);
      final url = '${s.base}/m/v.m3u8';
      ledger.value = jsonEncode([
        row(url: url, name: 'v.ts', hls: true, status: 'fetching', fetched: false,
            hlsSeg: 1, hlsBytes: 4000, hlsVariant: url)
      ]);
      final q = open();
      await q.restore();
      await settle(q);
      final t = q.tasks.single;
      expect(t.status, WebTaskStatus.done, reason: t.error);
      final expected = BytesBuilder()
        ..add(_bytes(4000, 20))
        ..add(_bytes(4000, 21))
        ..add(_bytes(4000, 22));
      expect(s.objects['downloads/v.ts'], expected.takeBytes());
      expect(s.rangesSeen.containsKey('a0.ts'), isFalse);
    });

    test('一時停止の行は止めたまま、失敗の行は理由付きで戻す', () async {
      ledger.value = jsonEncode([
        row(url: video('p.mp4').url, name: 'p.mp4', id: 'wold_1', status: 'paused', fetched: false),
        row(url: video('e.mp4').url, name: 'e.mp4', id: 'wold_2', status: 'error', fetched: false, error: 'HTTP 500'),
      ]);
      final q = open();
      await q.restore();
      await settle(q);
      expect(q.tasks.map((t) => t.status), [WebTaskStatus.paused, WebTaskStatus.error]);
      expect(q.tasks.last.error, 'HTTP 500');
      expect(s.mediaRequests, isEmpty);
    });

    test('台帳に入った http/https 以外の URL や壊れた行は戻さず、型の違う項目は無視する', () async {
      ledger.value = jsonEncode([
        row(url: 'file:///sdcard/a.mp4'),
        {'id': 3},
        'oops',
        // 型の違う項目が混じっても落ちない
        {...row(url: 'https://cdn.example.com/x.mp4', status: 'paused', fetched: false), 'hlsVariant': 5, 'size': 'big', 'headers': 'x'},
      ]);
      final q = open();
      await q.restore();
      expect(q.tasks.map((t) => t.url), ['https://cdn.example.com/x.mp4']);
      expect(q.tasks.single.hlsVariant, isNull);
      expect(q.tasks.single.headers, isEmpty);
      expect(s.mediaRequests, isEmpty);
    });

    test('壊れた台帳でも起動は止まらず、空から始める', () async {
      ledger.value = '{not json';
      final q = open();
      await q.restore();
      expect(q.tasks, isEmpty);
    });

    test('台帳に無い一時ファイルは片付ける', () async {
      await stage.create(recursive: true);
      File('${stage.path}/stray.mp4').writeAsBytesSync([1, 2, 3]);
      final q = open();
      await q.restore();
      expect(stage.listSync(), isEmpty);
    });

    test('台帳を読めなかった時は、前回の台帳も一時ファイルも消さない', () async {
      await stage.create(recursive: true);
      File('${stage.path}/wold_1.mp4').writeAsBytesSync(_bytes(100));
      final before = jsonEncode([row(url: video('clip.mp4').url, status: 'paused', fetched: false)]);
      ledger.value = before;
      ledger.failRead = true;
      final q = open();
      await q.restore();
      s.media['new.mp4'] = _bytes(10);
      q.enqueue('lib', [video('new.mp4')]);
      await settle(q);
      expect(ledger.value, before);
      expect(ledger.writes, 0);
      expect(File('${stage.path}/wold_1.mp4').existsSync(), isTrue);
      // 台帳に書けんでも、新しい取り込みは止めずに送り終える
      expect(q.tasks.where((t) => t.name == 'new.mp4').single.status, WebTaskStatus.done);
    });

    test('読み戻す前に積んだ取り込みでも、前回の台帳を上書きせず両方戻す', () async {
      s.media['new.mp4'] = _bytes(10);
      ledger.value = jsonEncode([
        row(url: video('old.mp4').url, name: 'old.mp4', status: 'paused', fetched: false),
      ]);
      final q = open();
      // 起動直後、台帳を読み終える前に積まれた
      q.enqueue('lib', [video('new.mp4')]);
      await q.restore();
      await settle(q);
      expect(q.tasks.map((t) => t.name), containsAll(['old.mp4', 'new.mp4']));
      expect(q.tasks.where((t) => t.name == 'old.mp4').single.status, WebTaskStatus.paused);
      expect(ledger.rows.map((r) => r['name']), ['old.mp4']);
    });

    test('完了にする時には、台帳からもう外れている（完了直後に畳まれても取り直さない）', () async {
      s.media['clip.mp4'] = _bytes(3000);
      final q = open();
      final seen = <bool>[];
      WebTransferTask? watched;
      q.addListener(() {
        final w = watched;
        if (w != null && w.status == WebTaskStatus.done) {
          seen.add(ledger.rows.any((r) => r['id'] == w.id));
        }
      });
      final t = q.enqueue('lib', [video('clip.mp4')]).single;
      watched = t;
      await settle(q);
      expect(t.status, WebTaskStatus.done, reason: t.error);
      expect(seen, isNotEmpty);
      expect(seen, everyElement(isFalse));
      expect((await q.history.list()).single.key, 'downloads/clip.mp4');
    });

    test('同じ名前・同じ大きさの別ファイルが先にあれば、自分の物とみなさず次の名前で送る', () async {
      final data = _bytes(3000);
      s.media['clip.mp4'] = data;
      s.objects['downloads/clip.mp4'] = _bytes(3000, 99);
      s.existingKeys.add('downloads/clip.mp4');
      final q = open();
      final t = q.enqueue('lib', [video('clip.mp4')]).single;
      await settle(q);
      expect(t.key, 'downloads/clip (2).mp4');
      expect(s.objects['downloads/clip (2).mp4'], data);
      expect(s.objects['downloads/clip.mp4'], _bytes(3000, 99));
    });

    test('何度呼んでも戻すのは1回だけ', () async {
      s.media['p.mp4'] = _bytes(10);
      ledger.value = jsonEncode([
        row(url: video('p.mp4').url, name: 'p.mp4', status: 'paused', fetched: false),
      ]);
      final q = open();
      await Future.wait([q.restore(), q.restore()]);
      await q.restore();
      expect(q.tasks, hasLength(1));
    });
  });
}
