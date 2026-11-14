import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/pairing.dart';
import 'theme.dart';

/// 接続中に設定から開く「接続先を変更」。保存するまで今の接続は変えない。
/// 初回用の ConnectScreen と分けているのは、こちらは戻る先（今の接続）があり、
/// 失敗しても「今のまま使える」ことを見せる必要があるため。
class ConnectEditScreen extends StatefulWidget {
  final AppState app;
  const ConnectEditScreen({super.key, required this.app});

  @override
  State<ConnectEditScreen> createState() => _ConnectEditScreenState();
}

class _ConnectEditScreenState extends State<ConnectEditScreen> {
  late final TextEditingController _endpoint;
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _okDetail;

  @override
  void initState() {
    super.initState();
    // 今の接続先を入れて開く。トークンは画面に出さないので空から入れ直す
    _endpoint = TextEditingController(text: widget.app.api.conn?.endpoint ?? '');
    _endpoint.addListener(() => _takePairing(_endpoint));
    _token.addListener(() => _takePairing(_token));
  }

  // どちらの欄に貼っても両方の欄を埋める（ConnectScreen と同じ）
  void _takePairing(TextEditingController from) {
    final p = parsePairingString(from.text);
    if (p == null) return;
    _endpoint.value = TextEditingValue(text: p.endpoint);
    _token.value = TextEditingValue(text: p.token);
    setState(() {
      _error = null;
      _okDetail = null;
    });
  }

  // トークン欄が空なら今のトークンのまま（デザインの「変えない時は空のまま」）。
  // 別のエンドポイントへ今のトークンを送ることになるが、確かめて通った時しか保存しない
  String get _effectiveToken {
    final t = _token.text.trim();
    return t.isNotEmpty ? t : (widget.app.api.conn?.token ?? '');
  }

  bool get _canSubmit =>
      _endpoint.text.trim().isNotEmpty && _effectiveToken.isNotEmpty;

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  void _edited() => setState(() {
        _error = null;
        _okDetail = null;
      });

  Future<void> _try() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _okDetail = null;
    });
    final r = await widget.app.tryConnect(_endpoint.text, _effectiveToken);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = r.error;
      _okDetail = r.error != null
          ? null
          : (r.libraryCount != null
              ? 'ライブラリ ${r.libraryCount} 件が見つかりました。保存すると切り替わります。'
              : '保存すると切り替わります。');
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // 確かめて成功した時だけ接続を差し替える。失敗では今の接続を触らず、理由（届かない／トークン）を出す
    final err = await widget.app.saveConnection(_endpoint.text, _effectiveToken);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = err;
      _okDetail = null;
    });
  }

  Widget _field(String label, TextEditingController c, String hint,
      {TextInputType? type, bool obscure = false, Key? fieldKey}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: AppColors.textDim, fontSize: 13, height: 20 / 13)),
        const SizedBox(height: 6),
        SizedBox(
          height: 52,
          child: TextField(
            key: fieldKey,
            controller: c,
            keyboardType: type,
            obscureText: obscure,
            onChanged: (_) => _edited(),
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle:
                  const TextStyle(color: AppColors.textDim, fontSize: 15),
              filled: true,
              fillColor: AppColors.surfaceHigh,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              border: _fieldBorder,
              enabledBorder: _fieldBorder,
              focusedBorder: _fieldBorder.copyWith(
                  borderSide: const BorderSide(color: AppColors.accent)),
            ),
          ),
        ),
      ],
    );
  }

  static final _fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(14),
    borderSide: const BorderSide(color: _outline),
  );
  // デザインの入力枠・ボタン枠の色
  static const _outline = Color(0xFF6E6C7C);
  static const _okColor = Color(0xFF7FD1A8);

  @override
  Widget build(BuildContext context) {
    final conn = widget.app.api.conn;
    final host = conn == null ? null : hostOf(conn.endpoint);
    final buttonShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    const buttonText = TextStyle(fontSize: 15, fontWeight: FontWeight.w700);
    return Scaffold(
      appBar: AppBar(title: const Text('接続先を変更')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            if (host != null) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(children: [
                  Container(
                    key: const Key('currentDot'),
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                        color: _okColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('今の接続先',
                            style: TextStyle(
                                color: AppColors.textDim,
                                fontSize: 13,
                                height: 20 / 13)),
                        Text(host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 15,
                                height: 22 / 15)),
                      ],
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
            ],
            _field('エンドポイント', _endpoint, 'https://…workers.dev',
                type: TextInputType.url, fieldKey: const Key('endpointField')),
            const SizedBox(height: 16),
            _field('アクセストークン', _token, '変えない時は空のまま',
                obscure: true, fieldKey: const Key('tokenField')),
            const SizedBox(height: 12),
            const Text(
              'r2g://setup… のペアリング文字列を、どちらの欄に貼り付けても入ります。',
              style: TextStyle(
                  color: AppColors.textDim, fontSize: 12, height: 18 / 12),
            ),
            if (_okDetail != null) ...[
              const SizedBox(height: 16),
              Container(
                key: const Key('okBox'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.check_circle_outline,
                            size: 24, color: _okColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('接続できました',
                                style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 14,
                                    height: 20 / 14)),
                            Text(_okDetail!,
                                style: const TextStyle(
                                    color: AppColors.textDim,
                                    fontSize: 12,
                                    height: 18 / 12)),
                          ],
                        ),
                      ),
                    ]),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    shape: buttonShape,
                    side: const BorderSide(color: _outline),
                    foregroundColor: AppColors.textPrimary,
                    textStyle: buttonText),
                onPressed: _busy || !_canSubmit ? null : _try,
                child: const Text('接続を試す'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    shape: buttonShape, textStyle: buttonText),
                onPressed: _busy || !_canSubmit ? null : _save,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('保存して切り替える'),
              ),
            ),
            const SizedBox(height: 16),
            // 失敗の理由はデザインどおりボタンの下の説明の位置に出す
            if (_error != null) ...[
              Text(_error!,
                  key: const Key('errorNote'),
                  style: const TextStyle(
                      color: AppColors.danger, fontSize: 12, height: 18 / 12)),
              const SizedBox(height: 4),
            ],
            const Text(
              'つながらなかった時は保存されず、今の接続のまま使えます。',
              style: TextStyle(
                  color: AppColors.textDim, fontSize: 12, height: 18 / 12),
            ),
          ],
        ),
      ),
    );
  }
}
