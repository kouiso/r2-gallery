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
  String? _ok;

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
      _ok = null;
    });
  }

  bool get _canSubmit =>
      _endpoint.text.trim().isNotEmpty && _token.text.trim().isNotEmpty;

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  void _edited() => setState(() {
        _error = null;
        _ok = null;
      });

  Future<void> _try() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    final r = await widget.app.tryConnect(_endpoint.text, _token.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = r.error;
      _ok = r.error != null
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
    // connect は確かめて成功した時だけ接続を差し替える。失敗では今の接続を触らない
    final err = await widget.app.connect(_endpoint.text, _token.text);
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = '$err 保存していないので、今の接続のまま使えます。';
      _ok = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final conn = widget.app.api.conn;
    final host = conn == null ? null : hostOf(conn.endpoint);
    return Scaffold(
      appBar: AppBar(title: const Text('接続先を変更')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (host != null)
              Card(
                child: ListTile(
                  title: const Text('今の接続先'),
                  subtitle: Text(host,
                      style: const TextStyle(
                          color: AppColors.textDim, fontSize: 12)),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _endpoint,
              decoration: const InputDecoration(
                  labelText: 'エンドポイント', hintText: 'https://…workers.dev'),
              keyboardType: TextInputType.url,
              onChanged: (_) => _edited(),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                  labelText: 'アクセストークン', hintText: 'r2g_…'),
              obscureText: true,
              onChanged: (_) => _edited(),
            ),
            const SizedBox(height: 6),
            const Text(
              'r2g://setup… のペアリング文字列を、どちらの欄に貼り付けても入ります。',
              style: TextStyle(color: AppColors.textDim, fontSize: 12),
            ),
            if (_ok != null) ...[
              const SizedBox(height: 14),
              Text('接続できました。$_ok',
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 13)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!,
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 13)),
            ],
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _busy || !_canSubmit ? null : _try,
              child: const Text('接続を試す'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _busy || !_canSubmit ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存して切り替える'),
            ),
            const SizedBox(height: 12),
            const Text(
              'つながらなかった時は保存されず、今の接続のまま使えます。',
              style: TextStyle(color: AppColors.textDim, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
