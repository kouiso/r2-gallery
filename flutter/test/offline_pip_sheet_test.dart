import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/offline/offline_playback_files.dart';
import 'package:r2_gallery/src/offline/offline_screen.dart';
import 'package:r2_gallery/src/offline/offline_store.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';
import 'package:r2_gallery/src/state/app_state.dart';

import 'offline_store_test.dart' show MemKv;
import 'support/fake_playback.dart';
import 'support/fake_video.dart';

class _App extends AppState {
  _App(this.base) : super(api: ApiClient(), bakedEndpoint: '', bakedToken: '', offline: base);
  final OfflineStore base;
  @override
  OfflineStore get offline => base.forAccount('synthetic');
  @override
  String? get offlineAccountId => 'synthetic';
  @override
  bool canReadOffline(String lib) => connected && !locked && lib == 'lib';
}

Future<void> _io(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(done(), isTrue);
}

void main() {
  late Directory temp;
  late OfflinePlaybackFiles files;
  late _App app;
  late OfflineRef item;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('r2g-pip-sheet-');
    files = OfflinePlaybackFiles(root: () async => temp);
    final kv = MemKv();
    kv.values[OfflineStore.dekKey] = base64Encode(Uint8List(32));
    app = _App(OfflineStore(kv: kv, dir: () async => temp));
    await app.offline.saveBytes(
        lib: 'lib', key: 'clip.mp4', type: 'video', name: 'clip.mp4',
        plain: Uint8List.fromList([1, 2, 3]));
    item = (await app.offline.list()).single;
  });

  tearDown(() async {
    app.dispose();
    await temp.delete(recursive: true);
  });

  testWidgets('オフライン動画で小窓へ入ると上に開いたシートを畳む', (tester) async {
    app.connected = true;
    app.deviceLockEnabled = false;
    app.hasPin = false;
    app.libraries = const [Library(id: 'lib', title: 'Fixture')];
    final port = FakePlaybackPort();
    final owner = PlaybackCoordinator(port);
    final video = FakeVideo();
    await tester.pumpWidget(MaterialApp(home: OfflineViewer(
      app: app, item: item, playbackFiles: files, controllerFactory: (_) => video,
      playbackCoordinator: owner,
    )));
    await _io(tester, () => video.value.isPlaying);
    final session = owner.current!;

    final ctx = tester.element(find.byType(OfflineViewer));
    unawaited(showModalBottomSheet<void>(
        context: ctx, builder: (_) => const Text('シート')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('シート'), findsOneWidget);

    expect(await session.enterPip(const Rect.fromLTWH(0, 0, 320, 180)), isTrue);
    session.pipChanged(true);
    for (var i = 0; i < 50 && find.text('シート').evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(session.pip, isTrue);
    expect(find.text('シート'), findsNothing);
    expect(find.byType(OfflineViewer), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
