import 'package:flutter/widgets.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';

class FakePlaybackPort implements PlaybackPort {
  PlaybackSession? bound;
  bool supported = true;
  bool focus = false;
  int pipRequests = 0;
  // armPip の呼び出し記録（armed, width, height）
  final arms = <(bool, int, int)>[];
  bool pipAllowed = true;
  // 許可は有るのに OS が断る場合（許可の問題ではない失敗）
  bool refuse = false;
  int settingsOpened = 0;
  @override
  Future<void> bind(PlaybackSession session) async {
    bound = session;
    session.pipSupported = supported;
    session.backgroundSupported = supported;
  }

  @override
  void update(PlaybackSession session) {}
  @override
  Future<void> clear(PlaybackSession session) async {
    // native と同じく、小窓の中で clear されたら小窓の session だけ覚えておく
    if (identical(bound, session)) {
      pipSession = session.pip ? session.id : null;
      bound = null;
    }
  }

  @override
  Future<bool> activateAudio(bool active) async {
    focus = active;
    return true;
  }

  @override
  Future<bool> enterPip(PlaybackSession session, Rect rect) async {
    pipRequests++;
    return supported && pipAllowed && !refuse;
  }

  @override
  Future<void> exitPip(PlaybackSession session) async {
    // native の session ガードと同じ。現在の session か、小窓の session だけを受ける
    final accepted = identical(bound, session) || pipSession == session.id;
    if (!accepted) {
      droppedExits++;
      return;
    }
    exits++;
    pipSession = null;
  }

  int exits = 0;
  // native が session 違いで捨てた exitPip の数
  int droppedExits = 0;
  String? pipSession;
  @override
  Future<void> visibility(PlaybackSession session) async {}
  @override
  void armPip(PlaybackSession session, bool armed, int width, int height) =>
      arms.add((armed, width, height));
  @override
  Future<bool> pipPermitted(PlaybackSession session) async => pipAllowed;
  @override
  Future<void> openPipSettings(PlaybackSession session) async =>
      settingsOpened++;
}
