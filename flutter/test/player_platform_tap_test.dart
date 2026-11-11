import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/playback/player_platform_tap.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Platform extends VideoPlayerPlatform {
  final creates = <Completer<int?>>[];
  final events = StreamController<VideoEvent>.broadcast();
  final calls = <Object>[];
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) {
    final gate = Completer<int?>();
    creates.add(gate);
    return gate.future;
  }

  @override
  Future<void> play(int playerId) async => calls.add(['play', playerId]);
  @override
  Future<void> pause(int playerId) async => calls.add(['pause', playerId]);
  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      calls.add(['seek', playerId, position]);
  @override
  Future<void> dispose(int playerId) async => calls.add(['dispose', playerId]);
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events.stream;
}

void main() {
  test('遅れて完了するnative IDを作成開始時の所有者へ返し、同じplatformへ操作を渡す', () async {
    final delegate = _Platform();
    addTearDown(delegate.events.close);
    final created = <(int, Object?)>[];
    final tap = PlayerPlatformTap(
      delegate,
      (id, owner) => created.add((id, owner)),
    );
    final options = VideoCreationOptions(
      viewType: VideoViewType.textureView,
      dataSource: DataSource(
        sourceType: DataSourceType.network,
        uri: 'https://fixture.invalid/a.mp4',
      ),
    );
    tap.creatingOwner = 'first';
    final first = tap.createWithOptions(options);
    tap.creatingOwner = 'second';
    final second = tap.createWithOptions(options);
    delegate.creates.last.complete(22);
    delegate.creates.first.complete(11);
    await Future.wait([first, second]);
    expect(created, [(22, 'second'), (11, 'first')]);
    await tap.play(11);
    await tap.pause(11);
    await tap.seekTo(11, const Duration(seconds: 42));
    final received = tap.videoEventsFor(11).first;
    final event = VideoEvent(eventType: VideoEventType.completed);
    delegate.events.add(event);
    expect(await received, same(event));
    await tap.dispose(11);
    expect(delegate.calls, [
      ['play', 11],
      ['pause', 11],
      ['seek', 11, const Duration(seconds: 42)],
      ['dispose', 11],
    ]);
  });
}
