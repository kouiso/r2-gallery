import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../store/pin.dart';
import 'theme.dart';

/// ロック画面。ロック中だけ全面を覆う。
/// 端末の画面ロック/生体で解除し、PIN があれば代わりに PIN でも解除できる（KMP版 LockScreen 相当）。
class LockGate extends StatefulWidget {
  final AppState app;
  const LockGate({super.key, required this.app});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  final _pin = TextEditingController();
  String? error;
  int expectedLen = 0;
  bool busy = false;
  bool deviceFailed = false;

  @override
  void initState() {
    super.initState();
    // 入った瞬間に一度だけ認証ダイアログを出す。失敗後はボタンで再試行
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _autoDeviceUnlock();
    });
    PinLock.pinLength().then((n) {
      if (mounted) setState(() => expectedLen = n ?? 0);
    });
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _autoDeviceUnlock() async {
    await widget.app.refreshDeviceLockAvailable();
    if (!mounted || !widget.app.deviceUnlockOffered) return;
    await _deviceUnlock();
  }

  Future<void> _deviceUnlock() async {
    final ok = await widget.app.deviceUnlock();
    if (mounted && !ok) setState(() => deviceFailed = true);
  }

  Future<void> _submit() async {
    if (busy) return;
    final left = await PinLock.lockedRemaining();
    if (left > 0) {
      setState(() => error = '試行回数超過。${(left / 1000).ceil()}秒待ってください');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final ok = await PinLock.verify(_pin.text);
    if (!mounted) return;
    if (ok) {
      await PinLock.clearFailures();
      widget.app.unlock();
    } else {
      final lock = await PinLock.recordFailure();
      setState(() {
        busy = false;
        error = lock > 0
            ? '試行回数超過。${(lock / 1000).ceil()}秒待ってください'
            : 'PINが違います';
        _pin.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: Center(
            // キーボードや大きい文字でも切れないよう縦スクロールにする
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: _body(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final app = widget.app;
    final device = app.deviceUnlockOffered;
    final hasPin = app.hasPin;

    // 認証手段が無いと確かめられた時だけ、閉じ込めずにそのまま続けられるようにする
    if (!device && !hasPin) return _noCredential();

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.lock_outline, size: 48, color: AppColors.accent),
        const SizedBox(height: 20),
        const Text('ロック中',
            textAlign: TextAlign.center,
            style: AppText.title),
        const SizedBox(height: 8),
        // 実際は取り込み含め画面全体を覆うので、対象を列挙せず「アプリ全体」と書く
        Text('このアプリを開くには、ロックを解除してください。',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: AppColors.textDim)),
        const SizedBox(height: 28),
        if (device) ...[
          FilledButton.icon(
            onPressed: _deviceUnlock,
            icon: const Icon(Icons.fingerprint),
            label: const Text('ロックを解除'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
          ),
          if (app.deviceLockProbe == DeviceLockProbe.unknown) ...[
            const SizedBox(height: 12),
            Text('端末の画面ロックを確認できませんでした。ボタンから認証を試せます。',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textDim)),
          ],
          if (deviceFailed) ...[
            const SizedBox(height: 12),
            Text('認証できませんでした。もう一度お試しください。',
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.danger)),
          ],
        ],
        if (device && hasPin) ...[
          const SizedBox(height: 24),
          Text('または PIN で解除',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textDim)),
          const SizedBox(height: 12),
        ],
        if (hasPin) ..._pinForm(autofocus: !device),
      ],
    );
  }

  List<Widget> _pinForm({required bool autofocus}) => [
        TextField(
          controller: _pin,
          autofocus: autofocus,
          keyboardType: TextInputType.number,
          obscureText: true,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 8),
          maxLength: expectedLen > 0 ? expectedLen : 8,
          decoration:
              const InputDecoration(counterText: '', hintText: 'PIN'),
          onSubmitted: (_) => _submit(),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.danger)),
        ],
        const SizedBox(height: 20),
        FilledButton(
            onPressed: busy ? null : _submit,
            child: const Text('PINで解除')),
      ];

  /// 端末に安全な画面ロックが無い時（KMP版 NoCredentialContent 相当）。
  Widget _noCredential() => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_outline, size: 48, color: AppColors.accent),
          const SizedBox(height: 20),
          const Text('画面ロックがありません',
              textAlign: TextAlign.center,
              style: AppText.title),
          const SizedBox(height: 8),
          Text(
              'このアプリは端末の画面ロック（PIN・パターン・指紋・顔）で保護します。'
              '端末の設定で画面ロックを有効にすると、次回起動時にロックがかかります。',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textDim)),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: widget.app.unlock,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            child: const Text('ロックなしで続ける'),
          ),
        ],
      );
}

/// 「今すぐロック」。ロックできない時は黙って無反応にせず理由と次の手を出す。
void lockNowOrExplain(BuildContext context, AppState app) {
  if (app.lockNow()) return;
  // 端末側は OS の画面ロックへ案内する。PIN の新設は web だけの動線（#29）
  final hint = app.isWeb
      ? (app.deviceLockEnabled
          ? 'この端末に画面ロックがありません。設定でPINを設定するとロックできます'
          : '画面ロックが切れています。設定でONにするかPINを設定してください')
      : (app.deviceLockEnabled
          ? 'この端末に画面ロックがありません。端末の設定で画面ロックを有効にしてください'
          : '画面ロックが切れています。設定でONにしてください');
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(hint)));
}
