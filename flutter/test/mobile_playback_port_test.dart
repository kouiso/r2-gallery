import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/playback/mobile_playback.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';

import 'support/fake_video.dart';

class _Audio extends Fake implements AudioSession {
  final activations = <bool>[];
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {}
  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.r2gallery/playback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _Audio audio;
  late NativePlaybackPort port;
  late PlaybackCoordinator owner;
  late PlaybackSession session;
  late FakeVideo video;
  late List<MethodCall> calls;
  var authorized = true;
  var failUpdate = false;

  Future<dynamic> native(String method, Map<String, dynamic> arguments) async {
    final done = Completer<ByteData?>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      done.complete,
    );
    return channel.codec.decodeEnvelope((await done.future)!);
  }

  setUp(() async {
    authorized = true;
    failUpdate = false;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'bind') return {'pip': true, 'background': true};
      if (call.method == 'update' && failUpdate) {
        throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    audio = _Audio();
    port = NativePlaybackPort(audio);
    owner = PlaybackCoordinator(port);
    port.coordinator = owner;
    video = FakeVideo();
    session = owner.create(
      controller: video,
      authorize: () async => authorized,
      backgroundBudget: () async => null,
      onRelock: () {},
    );
    session.nativePlayerId = 17;
    await session.initialize();
  });
  tearDown(() async {
    await session.close();
    session.dispose();
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('OS操作は同じsessionの認証を通し、古いtokenや無効seekを拒否する', () async {
    expect(
      await native('command', {'session': 'old', 'action': 'play'}),
      isFalse,
    );
    expect(video.plays, 0);
    authorized = false;
    expect(
      await native('command', {'session': session.id, 'action': 'play'}),
      isFalse,
    );
    expect(video.plays, 0);
    authorized = true;
    expect(
      await native('command', {'session': session.id, 'action': 'play'}),
      isTrue,
    );
    expect(video.plays, 1);
    await native('command', {'session': session.id, 'action': 'forward'});
    expect(video.value.position, const Duration(seconds: 30));
    expect(
      await native('command', {
        'session': session.id,
        'action': 'seek',
        'position': double.nan,
      }),
      isFalse,
    );
    await native('command', {
      'session': session.id,
      'action': 'seek',
      'position': 999999,
    });
    expect(video.value.position, const Duration(seconds: 60));
    await native('command', {'session': session.id, 'action': 'pause'});
    expect(video.value.isPlaying, isFalse);
    expect(audio.activations.last, isFalse);
  });

  test('nativeへ渡す情報は匿名の状態だけで、作品名・URL・資格情報・平文パスを含めない', () async {
    await session.play();
    await session.seek(const Duration(seconds: 29));
    await session.stop();
    expect(calls.first.arguments, {'session': session.id, 'playerId': 17});
    final updates = calls.where((c) => c.method == 'update');
    expect(updates, isNotEmpty);
    for (final call in updates) {
      expect((call.arguments as Map).keys.toSet(), {
        'session',
        'playing',
        'position',
        'duration',
        'buffering',
        'ended',
        'speed',
      });
      expect((call.arguments as Map).values.whereType<String>().toList(), [
        session.id,
      ]);
    }
    expect(calls.last.method, 'clear');
  });

  test('OS情報の更新失敗は背景で音声だけを残さず停止へ収束する', () async {
    await session.play();
    await session.setBackgroundAllowed(true);
    await session.lifecycle(AppLifecycleState.paused);
    failUpdate = true;
    video.value = video.value.copyWith(position: const Duration(seconds: 25));
    for (var i = 0; i < 20 && video.value.isPlaying; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await session.stop();
    expect(video.value.isPlaying, isFalse);
    expect(session.backgroundAllowed, isFalse);
    expect(session.message, contains('停止しました'));
    expect(audio.activations.last, isFalse);
  });
}
