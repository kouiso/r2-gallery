import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'lock_gate.dart';

/// ロックを Navigator より上に被せる層。MaterialApp.builder から使う。
/// home を差し替える方式だと、上に積んだ再生画面・シート・ダイアログが残って見え、操作もできてしまう。
/// 下の木は捨てずに生かしておき（選んだファイルやアップロード中のシートを失わない）、
/// ロック中は描かず・触らせず・フォーカスも渡さない。
class AppLockLayer extends StatelessWidget {
  final AppState app;
  final Widget child;
  const AppLockLayer({super.key, required this.app, required this.child});

  @override
  Widget build(BuildContext context) {
    return AppLockScope(
      app: app,
      child: ListenableBuilder(
        listenable: app,
        child: child,
        builder: (context, content) {
          final locked = app.sessionOpen && app.locked && !app.loading;
          return Stack(
            fit: StackFit.expand,
            children: [
              Offstage(
                offstage: locked,
                child: TickerMode(
                  enabled: !locked,
                  child: ExcludeFocus(
                    excluding: locked,
                    child: ExcludeSemantics(
                      excluding: locked,
                      child: IgnorePointer(ignoring: locked, child: content),
                    ),
                  ),
                ),
              ),
              // TextField の選択ハンドル等は Overlay が要るが、ここは Navigator の外なので自前で持つ
              if (locked) _LockOverlay(app: app),
            ],
          );
        },
      ),
    );
  }
}

class _LockOverlay extends StatefulWidget {
  final AppState app;
  const _LockOverlay({required this.app});

  @override
  State<_LockOverlay> createState() => _LockOverlayState();
}

class _LockOverlayState extends State<_LockOverlay> {
  late final OverlayEntry _entry =
      OverlayEntry(builder: (_) => LockGate(app: widget.app));

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

/// 積まれた画面からロック状態を引くための口。再生画面がロックで動画を止めるのに使う。
class AppLockScope extends InheritedWidget {
  final AppState app;
  const AppLockScope({super.key, required this.app, required super.child});

  static AppState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppLockScope>()?.app;

  @override
  bool updateShouldNotify(AppLockScope oldWidget) => app != oldWidget.app;
}

/// ロックされた瞬間に onLocked を呼ぶ。画面を隠しても音は鳴り続けるので、再生物は止める。
mixin PauseOnLock<T extends StatefulWidget> on State<T> {
  AppState? _lockApp;
  bool _wasLocked = false;

  void onLocked();

  /// いまロック中か。ロック中に読み込みが終わった動画を勝手に再生しないために使う。
  bool get isAppLocked => _lockApp?.locked ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppLockScope.maybeOf(context);
    if (app == _lockApp) return;
    _lockApp?.removeListener(_onLockChange);
    _lockApp = app;
    _wasLocked = app?.locked ?? false;
    app?.addListener(_onLockChange);
  }

  void _onLockChange() {
    final now = _lockApp?.locked ?? false;
    if (now && !_wasLocked) onLocked();
    _wasLocked = now;
  }

  @override
  void dispose() {
    _lockApp?.removeListener(_onLockChange);
    super.dispose();
  }
}
