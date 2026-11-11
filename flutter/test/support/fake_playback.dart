import 'package:flutter/widgets.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';

class FakePlaybackPort implements PlaybackPort {
  PlaybackSession? bound;
  bool supported = true;
  bool focus = false;
  int pipRequests = 0;
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
    if (identical(bound, session)) bound = null;
  }

  @override
  Future<bool> activateAudio(bool active) async {
    focus = active;
    return true;
  }

  @override
  Future<bool> enterPip(PlaybackSession session, Rect rect) async {
    pipRequests++;
    return supported;
  }

  @override
  Future<void> exitPip(PlaybackSession session) async {}
  @override
  Future<void> visibility(PlaybackSession session) async {}
}
