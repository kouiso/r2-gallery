import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'src/state/app_state.dart';
import 'src/store/lock_platform.dart';
import 'src/ui/app_lock_layer.dart';
import 'src/ui/connect_screen.dart';
import 'src/ui/home_shell.dart';
import 'src/ui/startup_banner.dart';
import 'src/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const R2GalleryApp());
}

class R2GalleryApp extends StatefulWidget {
  /// テストでは状態・窓の保護・リンク受信を差し替える。
  final AppState? app;
  final SecureWindow? secureWindow;
  final bool listenDeepLinks;
  const R2GalleryApp({
    super.key,
    this.app,
    this.secureWindow,
    this.listenDeepLinks = true,
  });

  @override
  State<R2GalleryApp> createState() => _R2GalleryAppState();
}

class _R2GalleryAppState extends State<R2GalleryApp>
    with WidgetsBindingObserver {
  late final AppState app = widget.app ?? AppState();
  late final SecureWindow _secureWindow =
      widget.secureWindow ?? PlatformSecureWindow();
  bool? _secureApplied;
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.addListener(_syncSecureWindow);
    _syncSecureWindow();
    if (widget.app == null) app.init();
    if (widget.listenDeepLinks) _listenDeepLinks();
  }

  void _syncSecureWindow() {
    final want = app.wantsSecureWindow;
    if (want == _secureApplied) return;
    _secureApplied = want;
    _secureWindow.setSecure(want);
  }

  void _listenDeepLinks() {
    final appLinks = AppLinks();
    // r2g://setup?endpoint=..&token=.. のペアリングリンクを受ける
    _linkSub = appLinks.uriLinkStream.listen((u) {
      if (u.scheme == 'r2g' && u.host == 'setup') {
        app.connectFromUri(u);
      }
    });
    appLinks.getInitialLink().then((u) {
      if (u != null && u.scheme == 'r2g' && u.host == 'setup') {
        app.connectFromUri(u);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.removeListener(_syncSecureWindow);
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive は認証ダイアログや通知シェードでも出るので、完全に裏へ行った paused だけ数える
    if (state == AppLifecycleState.paused) {
      app.onBackground();
    } else if (state == AppLifecycleState.detached) {
      app.onDetached();
    } else if (state == AppLifecycleState.resumed) {
      app.onForeground();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'R2 Gallery',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      // ロックは Navigator の上に被せる。積んだ再生画面やシートもまとめて隠し、下の木は捨てない
      builder: (context, child) =>
          AppLockLayer(app: app, child: child ?? const SizedBox.shrink()),
      home: AnimatedBuilder(
        animation: app,
        builder: (context, _) {
          if (app.loading) {
            return const Scaffold(
                body: Center(child: CircularProgressIndicator()));
          }
          return StartupErrorBanner(
            app: app,
            child: app.sessionOpen
                ? HomeShell(app: app)
                : ConnectScreen(app: app),
          );
        },
      ),
    );
  }
}
