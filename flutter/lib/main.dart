import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'src/state/app_state.dart';
import 'src/state/pairing.dart';
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
  final _navKey = GlobalKey<NavigatorState>();

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
    _linkSub = appLinks.uriLinkStream.listen(onPairingLink);
    appLinks.getInitialLink().then((u) {
      if (u != null) onPairingLink(u);
    });
  }

  /// ペアリングリンクの受け口。繋がっている時に別の送り先を指すリンクは、踏んだだけで
  /// 待っているアップロードの送り先が変わるので、切り替える前に確認を取る。
  /// 未接続（初回のペアリング）と同じ送り先へのリンクは、これまで通り確認なしで繋ぐ
  Future<void> onPairingLink(Uri u) async {
    if (u.scheme != 'r2g' || u.host != 'setup') return;
    // 保存した接続の復元が終わる前に判定すると、繋がっているのに未接続として扱ってしまう
    await app.ready;
    final params = app.pairingParams(u);
    if (params == null) return;
    if (app.pairingNeedsConfirm(u)) {
      final ctx = _navKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      // 設定からの切り替えと同じ理由で止める。connect 側でも止まるが、黙って返さず理由を見せる
      if (app.hasUnsentTransfers) {
        ScaffoldMessenger.of(ctx).showSnackBar(
            const SnackBar(content: Text(AppState.unsentTransfersMessage)));
        return;
      }
      final cur = app.api.conn?.endpoint ?? '';
      final ok = await showDialog<bool>(
        context: ctx,
        builder: (dctx) => AlertDialog(
          title: const Text('接続先を変更しますか？'),
          content: Text(
              '接続先を ${hostOf(cur)} から ${hostOf(params.endpoint)} に変えます。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: const Text('やめる'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: const Text('変更する'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    // 確認を出している間に未送信が積まれた時など、止まった理由は黙って捨てない
    final err = await app.connect(params.endpoint, params.token);
    if (err == null) return;
    final ctx = _navKey.currentContext;
    if (ctx != null && ctx.mounted) {
      ScaffoldMessenger.of(ctx)
          .showSnackBar(SnackBar(content: Text(err)));
    }
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
      navigatorKey: _navKey,
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
