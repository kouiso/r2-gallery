import 'dart:async';

/// 未対応・取得拒否・OS による解放を、保持できた状態と混同しない。
enum ScreenAwakeStatus { idle, acquiring, held, released, unsupported, denied, failed }

enum ScreenAwakeEvent { released, visibilityChanged }

abstract class ScreenAwakeDriver {
  bool get visible;
  Stream<ScreenAwakeEvent> get events;
  Future<ScreenAwakeStatus> acquire();
  Future<void> release();
  void dispose();
}
