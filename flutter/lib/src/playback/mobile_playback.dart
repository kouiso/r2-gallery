import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../state/app_state.dart';
import 'playback_session.dart';
import 'player_platform_tap.dart';

class MobilePlayback {
  static PlaybackCoordinator? coordinator;

  static bool get isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static VideoPlayerOptions options() => VideoPlayerOptions(
    allowBackgroundPlayback: coordinator != null,
    // 音声フォーカスは audio_session へ集約し、ExoPlayer と二重に要求しない。
    mixWithOthers: coordinator != null,
    preventsDisplaySleepDuringVideoPlayback: false,
  );

  static Future<void> initialize() async {
    if (!isMobile || coordinator != null) return;
    final audio = await AudioSession.instance;
    final port = NativePlaybackPort(audio);
    final owner = PlaybackCoordinator(port);
    port.coordinator = owner;
    final tap = PlayerPlatformTap(VideoPlayerPlatform.instance, (id, creating) {
      if (creating is PlaybackSession) creating.nativePlayerId = id;
    });
    owner.onCreating = (session) => tap.creatingOwner = session;
    VideoPlayerPlatform.instance = tap;
    coordinator = owner;
    audio.interruptionEventStream.listen((event) {
      unawaited(
        owner.current?.interrupt(
          begin: event.begin,
          resume: event.type != AudioInterruptionType.unknown,
        ),
      );
    });
    audio.becomingNoisyEventStream.listen((_) {
      unawaited(owner.current?.pause());
    });
  }
}

/// URL・資格情報・ファイル名・復号パスを OS メディア情報へ渡さない。
class NativePlaybackPort implements PlaybackPort {
  NativePlaybackPort(
    this.audio, {
    this.channel = const MethodChannel('app.r2gallery/playback'),
  }) {
    channel.setMethodCallHandler(_receive);
  }
  final AudioSession audio;
  final MethodChannel channel;
  late PlaybackCoordinator coordinator;
  PlaybackSession? _bound;
  Future<void> _updates = Future<void>.value();

  Future<dynamic> _receive(MethodCall call) async {
    final args = call.arguments;
    if (args is! Map) return false;
    final session = coordinator.current;
    if (session == null || !session.live || args['session'] != session.id) {
      return false;
    }
    if (call.method == 'pipChanged') {
      session.pipChanged(
        args['active'] == true,
        // native が閉じた時点の状態で決めた値。無ければ古い経路として null のまま渡す
        restoring: args.containsKey('restoring')
            ? args['restoring'] == true
            : null,
        failed: args['failed'] == true,
      );
      return true;
    }
    if (call.method != 'command') return false;
    switch (args['action']) {
      case 'play':
        await session.play();
        return session.live && session.controller.value.isPlaying;
      case 'pause':
        await session.pause();
      case 'stop':
        await session.stop();
      case 'close':
        await session.close();
      case 'seek':
        final ms = args['position'];
        if (ms is! num || !ms.isFinite) return false;
        await session.seek(Duration(milliseconds: ms.round()));
      case 'forward':
        await session.seek(
          session.controller.value.position + const Duration(seconds: 10),
        );
      case 'rewind':
        await session.seek(
          session.controller.value.position - const Duration(seconds: 10),
        );
      default:
        return false;
    }
    return true;
  }

  @override
  Future<void> bind(PlaybackSession session) async {
    _bound = session;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('bind', {
        'session': session.id,
        'playerId': session.nativePlayerId,
      });
      session.pipSupported = result?['pip'] == true;
      session.backgroundSupported = result?['background'] == true;
    } on PlatformException {
      session.message = 'システムの再生操作を準備できませんでした';
    } on MissingPluginException {
      session.message = 'この環境ではシステムの再生操作を利用できません';
    }
    update(session);
  }

  @override
  void update(PlaybackSession session) {
    if (!identical(_bound, session)) return;
    final value = session.controller.value;
    final state = <String, dynamic>{
      'session': session.id,
      'playing': value.isPlaying,
      'position': value.position.inMilliseconds,
      'duration': value.duration.inMilliseconds,
      'buffering': value.isBuffering,
      'ended': value.isCompleted,
      'speed': value.playbackSpeed,
    };
    _updates = _updates
        .then((_) async {
          if (!identical(_bound, session) || !session.live) return;
          await channel.invokeMethod<void>('update', state);
        })
        .catchError((Object _) {
          // Native の診断に署名URLや例外の私的な詳細を混ぜない。
          debugPrint('system media state unavailable');
          if (identical(_bound, session) && session.live) {
            session.systemUnavailable();
          }
        });
  }

  @override
  Future<void> clear(PlaybackSession session) async {
    if (!identical(_bound, session)) return;
    _bound = null;
    await _updates;
    try {
      await channel.invokeMethod<void>('clear', {'session': session.id});
    } on PlatformException {
      debugPrint('system media cleanup unavailable');
    } on MissingPluginException {
      debugPrint('system media cleanup unsupported');
    }
  }

  @override
  Future<bool> activateAudio(bool active) async {
    try {
      if (active) {
        // video_player の初期化後に設定し、iOS側も別の音声と混ぜない方針に揃える。
        await audio.configure(const AudioSessionConfiguration.music());
      }
      return await audio.setActive(active);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> enterPip(PlaybackSession session, Rect rect) async {
    if (!identical(_bound, session)) return false;
    return await channel.invokeMethod<bool>('enterPip', {
          'session': session.id,
          'left': rect.left,
          'top': rect.top,
          'width': rect.width,
          'height': rect.height,
          // 縦横比は native で整数のまま OS の範囲へ収める
          'videoWidth': _px(session.controller.value.size.width),
          'videoHeight': _px(session.controller.value.size.height),
        }) ??
        false;
  }

  static int _px(double v) => v.isFinite ? v.round() : 0;

  @override
  Future<void> exitPip(PlaybackSession session) async {
    try {
      await channel.invokeMethod<void>('exitPip', {'session': session.id});
    } on PlatformException {
      debugPrint('picture in picture cleanup unavailable');
    } on MissingPluginException {
      // 非対応の環境で別の再生器を起動して代用しない。
    }
  }

  @override
  void armPip(PlaybackSession session, bool armed, int width, int height) {
    if (!identical(_bound, session)) return;
    // 通知の取りこぼしで例外を外へ漏らさない。届かなければ native は従来どおり入らない。
    unawaited(
      channel
          .invokeMethod<void>('armPip', {
            'session': session.id,
            'armed': armed,
            'width': width,
            'height': height,
          })
          .catchError(
            (Object _) => debugPrint('picture in picture arm unavailable'),
          ),
    );
  }

  @override
  Future<bool> pipPermitted(PlaybackSession session) async {
    try {
      return await channel.invokeMethod<bool>('pipPermitted', {
            'session': session.id,
          }) ??
          true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<void> openPipSettings(PlaybackSession session) async {
    try {
      await channel.invokeMethod<void>('openPipSettings', {
        'session': session.id,
      });
    } on PlatformException {
      debugPrint('picture in picture settings unavailable');
    } on MissingPluginException {
      // 設定画面を持たない環境では何もしない。
    }
  }

  @override
  Future<void> visibility(PlaybackSession session) async {
    try {
      await channel.invokeMethod<void>('visibility', {
        'session': session.id,
        'foreground': session.foreground,
        'pip': session.pip || session.pipPending,
      });
    } on PlatformException {
      debugPrint('media visibility unavailable');
    } on MissingPluginException {
      // Widgetテストや非対応platformではOS窓を操作しない。
    }
  }
}

class PlaybackBinding {
  PlaybackBinding._(this.session, this.app, this._appChanged);
  final PlaybackSession session;
  final AppState? app;
  final VoidCallback _appChanged;

  static PlaybackBinding? attach({
    required VideoPlayerController controller,
    required AppState? app,
    String? library,
    PlaybackCoordinator? coordinator,
    bool Function()? canAccess,
  }) {
    final owner = coordinator ?? MobilePlayback.coordinator;
    if (owner == null) return null;
    final account = app?.offlineAccountId;
    final lib = library ?? app?.activeLib;
    bool connectionValid() =>
        (canAccess?.call() ?? true) &&
        (app == null ||
            (account != null &&
                account == app.offlineAccountId &&
                app.connected &&
                (app.locked || (lib != null && app.canReadOffline(lib)))));
    late PlaybackSession session;
    session = owner.create(
      controller: controller,
      authorize: () async {
        if (!connectionValid() || (app?.locked ?? false)) return false;
        if (session.foreground && app != null) {
          await Future<void>.value();
          await app.foregroundSettled;
        }
        return connectionValid() && !(app?.locked ?? false);
      },
      backgroundBudget: () =>
          app?.backgroundPlaybackBudget() ?? Future.value(null),
      onRelock: () => app?.lockNow(),
      onPipBackground: () => app?.onBackground(),
      canEnterPip: () => app == null || !app.canLock || app.relockGraceMs > 0,
      isLocked: () => app?.locked ?? false,
    );
    void changed() => session.authorizationChanged(
      connectionChanged: !connectionValid(),
      locked: app?.locked ?? false,
    );
    app?.addListener(changed);
    return PlaybackBinding._(session, app, changed);
  }

  Future<void> close() async {
    app?.removeListener(_appChanged);
    await session.close();
    session.dispose();
  }
}
