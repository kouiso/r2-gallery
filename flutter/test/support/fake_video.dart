import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 端末の動画プレイヤーの代わり。再生状態を手で動かせる。
class FakeVideo extends ValueNotifier<VideoPlayerValue>
    implements VideoPlayerController {
  FakeVideo({this.failInit = false})
      : super(const VideoPlayerValue(duration: Duration.zero));
  final bool failInit;
  final seeks = <Duration>[];
  int plays = 0;
  int pauses = 0;
  final volumeSets = <double>[];

  @override
  Future<void> initialize() async {
    if (failInit) throw Exception('cannot open');
    value = value.copyWith(
      isInitialized: true,
      duration: const Duration(seconds: 60),
      position: const Duration(seconds: 20),
      size: const Size(16, 9),
    );
  }

  @override
  Future<void> play() async {
    plays++;
    value = value.copyWith(isPlaying: true, isCompleted: false);
  }

  @override
  Future<void> pause() async {
    pauses++;
    value = value.copyWith(isPlaying: false);
  }

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
    value = value.copyWith(position: position, isCompleted: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeSets.add(volume);
    value = value.copyWith(volume: volume);
  }

  @override
  int get playerId => VideoPlayerController.kUninitializedPlayerId;

  bool disposed = false;

  @override
  Future<void> dispose() async {
    disposed = true;
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
