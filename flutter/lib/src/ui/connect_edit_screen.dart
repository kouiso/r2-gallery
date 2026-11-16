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
    // 今の接続先を入れて開く。トークンは画面に出さないので欄は空で開く
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

  static const _needTokenMessage = '接続先を変える時は、新しい接続先のトークンを入れてください。';

  // トークン欄が空なら今のトークンのまま（デザインの「変えない時は空のまま」）。
  // ただし同じホストの時だけ。打ち間違えたよそのホストへ今のトークンを送らないため、null を返して止める
  String? get _effectiveToken {
    final t = _token.text.trim();
    if (t.isNotEmpty) return t;
    final conn = widget.app.api.conn;
    if (conn == null || conn.token.isEmpty) return null;
    return isSameHost(conn.endpoint, _endpoint.text) ? conn.token : null;
  }

  // トークンの有無で押せなくすると、なぜ押せないかが伝わらない。押した時に理由を出す
  bool get _canSubmit => _endpoint.text.trim().isNotEmpty;

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
    final token = _effectiveToken;
    if (token == null) return _refuseNoToken();
    setState(() {
      _busy = true;
      _error = null;
      _okDetail = null;
    });
    final r = await widget.app.tryConnect(_endpoint.text, token);
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

  void _refuseNoToken() => setState(() {
        _error = _needTokenMessage;
        _okDetail = null;
      });

  Future<void> _save() async {
    if (_busy) return;
    final token = _effectiveToken;
    if (token == null) return _refuseNoToken();
    setState(() {
      _busy = true;
      _error = null;
    });
    // 確かめて成功した時だけ接続を差し替える。失敗では今の接続を触らず、理由（届かない／トークン）を出す
    final err = await widget.app.saveConnection(_endpoint.text, token);
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
            style: AppText.caption.copyWith(color: AppColors.textDim)),
        const SizedBox(height: 6),
        SizedBox(
          height: 52,
          child: TextField(
            key: fieldKey,
            controller: c,
            keyboardType: type,
            obscureText: obscure,
            onChanged: (_) => _edited(),
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: AppText.body.copyWith(color: AppColors.textDim),
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
    borderRadius: BorderRadius.circular(AppRadius.medium),
    borderSide: const BorderSide(color: _outline),
  );
  // デザインの入力枠・ボタン枠の色
  static const _outline = AppColors.borderStrong;
  static const _okColor = AppColors.success;

  @override
  Widget build(BuildContext context) {
    final conn = widget.app.api.conn;
    final host = conn == null ? null : hostOf(conn.endpoint);
    final buttonShape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.medium));
    const buttonText = AppText.label;
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
                  borderRadius: BorderRadius.circular(AppRadius.large),
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
                        Text('今の接続先',
                            style: AppText.caption.copyWith(
                                color: AppColors.textDim)),
                        Text(host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.body.copyWith(
                                color: AppColors.textPrimary)),
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
            Text(
              'r2g://setup… のペアリング文字列を、どちらの欄に貼り付けても入ります。',
              style: AppText.caption.copyWith(color: AppColors.textDim),
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
                  borderRadius: BorderRadius.circular(AppRadius.large),
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
                            Text('接続できました',
                                style: AppText.body.copyWith(
                                    color: AppColors.textPrimary)),
                            Text(_okDetail!,
                                style: AppText.caption.copyWith(
                                    color: AppColors.textDim)),
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
            // 失敗の時はデザインどおり、下の説明と入れ替えて理由だけを出す
            if (_error != null)
              Text(_error!,
                  key: const Key('errorNote'),
                  style: AppText.caption.copyWith(
                      color: AppColors.danger))
            else
              Text(
                'つながらなかった時は保存されず、今の接続のまま使えます。',
                style: AppText.caption.copyWith(
                    color: AppColors.textDim),
              ),
          ],
        ),
      ),
    );
  }
}
