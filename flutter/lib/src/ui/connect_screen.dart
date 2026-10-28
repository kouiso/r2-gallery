import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/pairing.dart';
import 'theme.dart';

/// 接続設定（endpoint + token 入力）。初回と切断後、接続が要るタブで出る。
class ConnectScreen extends StatefulWidget {
  final AppState app;

  /// 「接続せずに取り込みだけ使う」。既定は取り込みだけ使う状態へ移る。
  /// 接続が要るタブの中に出す時は、取り込みタブへ移すよう差し替える。
  final VoidCallback? onSkip;
  const ConnectScreen({super.key, required this.app, this.onSkip});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _endpoint = TextEditingController();
  final _token = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _endpoint.addListener(() => _takePairing(_endpoint));
    _token.addListener(() => _takePairing(_token));
  }

  // 別端末から送ったペアリング文字列をどちらの欄に貼っても、両方の欄を埋める
  void _takePairing(TextEditingController from) {
    final p = parsePairingString(from.text);
    if (p == null) return;
    _endpoint.value = TextEditingValue(text: p.endpoint);
    _token.value = TextEditingValue(text: p.token);
    setState(() => error = null);
  }

  bool get _canSubmit =>
      _endpoint.text.trim().isNotEmpty && _token.text.trim().isNotEmpty;

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    final err = await widget.app.connect(_endpoint.text, _token.text);
    if (!mounted) return;
    setState(() {
      busy = false;
      error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final probeFailed = widget.app.bakedProbeFailed;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.photo_library_outlined,
                      size: 56, color: AppColors.accent),
                  const SizedBox(height: 16),
                  const Text(
                    'R2 Gallery',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 黙って入力欄だけ出すと「なぜ聞かれたのか」が分からんので、埋め込み接続の失敗を明示する
                  Text(
                    probeFailed ? '接続先に到達できません' : 'サーバーに接続',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    probeFailed
                        ? '設定済みの接続先に接続できませんでした。ネットワークを確認して接続を試すか、接続先を入力し直してください。'
                        : '写真を見るには接続先を設定してください。取り込みだけなら接続なしで使えます。',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: AppColors.textDim, fontSize: 13),
                  ),
                  const SizedBox(height: 36),
                  TextField(
                    controller: _endpoint,
                    decoration: const InputDecoration(
                      labelText: 'エンドポイント',
                      hintText: 'https://…workers.dev',
                    ),
                    keyboardType: TextInputType.url,
                    autofillHints: const [AutofillHints.url],
                    onChanged: (_) => setState(() => error = null),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _token,
                    decoration: const InputDecoration(
                      labelText: 'アクセストークン',
                      hintText: 'r2g_…',
                    ),
                    obscureText: true,
                    onChanged: (_) => setState(() => error = null),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'r2g://setup… のペアリング文字列を貼り付けても接続できます',
                    style: TextStyle(color: AppColors.textDim, fontSize: 12),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 14),
                    Text(error!,
                        style: const TextStyle(
                            color: AppColors.danger, fontSize: 13)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: busy || !_canSubmit ? null : _connect,
                    child: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('接続する'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed:
                        busy ? null : (widget.onSkip ?? widget.app.skipConnect),
                    child: const Text('接続せずに取り込みだけ使う'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
