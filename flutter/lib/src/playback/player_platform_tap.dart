import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// 公開の platform 作成結果だけを使い、controller のテスト専用 playerId に依存しない。
class PlayerPlatformTap extends VideoPlayerPlatform {
  PlayerPlatformTap(this.delegate, this.created);
  final VideoPlayerPlatform delegate;
  final void Function(int playerId, Object? owner) created;
  Object? creatingOwner;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final owner = creatingOwner;
    final id = await delegate.createWithOptions(options);
    if (id != null) created(id, owner);
    return id;
  }

  @override
  Future<void> init() => delegate.init();
  @override
  Future<void> dispose(int playerId) => delegate.dispose(playerId);
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      delegate.videoEventsFor(playerId);
  @override
  Future<void> play(int playerId) => delegate.play(playerId);
  @override
  Future<void> pause(int playerId) => delegate.pause(playerId);
  @override
  Future<void> setLooping(int playerId, bool looping) =>
      delegate.setLooping(playerId, looping);
  @override
  Future<void> setVolume(int playerId, double volume) =>
      delegate.setVolume(playerId, volume);
  @override
  Future<void> seekTo(int playerId, Duration position) =>
      delegate.seekTo(playerId, position);
  @override
  Future<Duration> getPosition(int playerId) => delegate.getPosition(playerId);
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) =>
      delegate.setPlaybackSpeed(playerId, speed);
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      delegate.buildViewWithOptions(options);
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) =>
      delegate.setMixWithOthers(mixWithOthers);
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) =>
      delegate.setAllowBackgroundPlayback(allowBackgroundPlayback);
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool preventsDisplaySleepDuringVideoPlayback,
  ) => delegate.setPreventsDisplaySleepDuringVideoPlayback(
    playerId,
    preventsDisplaySleepDuringVideoPlayback,
  );
  @override
  Future<void> setWebOptions(int playerId, VideoPlayerWebOptions options) =>
      delegate.setWebOptions(playerId, options);
  @override
  Future<List<VideoAudioTrack>> getAudioTracks(int playerId) =>
      delegate.getAudioTracks(playerId);
  @override
  Future<void> selectAudioTrack(int playerId, String trackId) =>
      delegate.selectAudioTrack(playerId, trackId);
  @override
  bool isAudioTrackSupportAvailable() =>
      delegate.isAudioTrackSupportAvailable();
  @override
  Future<List<VideoTrack>> getVideoTracks(int playerId) =>
      delegate.getVideoTracks(playerId);
  @override
  Future<void> selectVideoTrack(int playerId, VideoTrack? track) =>
      delegate.selectVideoTrack(playerId, track);
  @override
  bool isVideoTrackSupportAvailable() =>
      delegate.isVideoTrackSupportAvailable();
}
