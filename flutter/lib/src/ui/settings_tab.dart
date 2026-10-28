import 'package:flutter/material.dart';

import '../offline/offline_screen.dart';
import '../state/app_state.dart';
import '../state/pairing.dart';
import '../store/lock_policy.dart';
import '../store/pin.dart';
import 'lock_gate.dart';
import 'theme.dart';

// 接続中の印。KMP 版 SuccessGreen と同じ色
const _connectedGreen = Color(0xFF7FD1A8);

/// 設定タブ: 接続情報・ロック（画面ロック/再ロック/今すぐ/PIN）・切断。
class SettingsTab extends StatefulWidget {
  final AppState app;
  const SettingsTab({super.key, required this.app});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  Future<void> _editPin({required bool isNew}) async {
    final app = widget.app;
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(isNew ? 'PINを設定' : 'PINを変更'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: c1,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              decoration: const InputDecoration(labelText: '新しいPIN'),
            ),
            TextField(
              controller: c2,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              decoration: const InputDecoration(labelText: '確認用'),
            ),
            if (err != null)
              Text(err!, style: const TextStyle(color: AppColors.danger)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('キャンセル')),
            FilledButton(
              onPressed: () async {
                if (c1.text.length < 4) {
                  setS(() => err = '4桁以上にしてください');
                  return;
                }
                if (c1.text != c2.text) {
                  setS(() => err = '一致しません');
                  return;
                }
                await PinLock.setPin(c1.text);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('設定'),
            ),
          ],
        ),
      ),
    );
    c1.dispose();
    c2.dispose();
    if (ok == true) {
      await app.refreshPinState();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('PINを設定しました')));
      }
    }
  }

  Future<void> _removePin() async {
    final app = widget.app;
    await PinLock.removePin();
    await app.refreshPinState();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PINを解除しました')));
    }
  }

  Future<void> _pickGrace() async {
    final app = widget.app;
    final ms = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('再ロックまでの時間'),
        children: [
          for (final o in graceOptions)
            ListTile(
              title: Text(o.$2),
              trailing: app.relockGraceMs == o.$1
                  ? const Icon(Icons.check, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(ctx, o.$1),
            ),
        ],
      ),
    );
    if (ms != null) await app.setRelockGraceMs(ms);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    // KMP版と同じく、画面ロックが使えない端末/ブラウザでは切り替えられない
    final canToggleDeviceLock = app.deviceLockAvailable;
    // 長い URL をそのまま出さず、ホスト名だけにする。トークンは決して出さない
    final conn = app.api.conn;
    final host = app.connected && conn != null ? hostOf(conn.endpoint) : null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: host != null ? _connectedGreen : AppColors.textDim,
              ),
            ),
            title: Text(host != null ? '接続中' : '未接続'),
            subtitle: host != null
                ? Text('$host · ライブラリ ${app.libraries.length}',
                    style: const TextStyle(
                        color: AppColors.textDim, fontSize: 12))
                : const Text('タップして接続先を設定',
                    style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            onTap: host != null ? null : app.leaveBrowseOnly,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.fingerprint, color: AppColors.accent),
            title: const Text('画面ロックで保護'),
            subtitle: Text(
                canToggleDeviceLock || app.deviceLockEnabled
                    ? '写真・アルバム・設定を開くとき、指紋・顔・PINを求めます'
                    : 'この端末では画面ロックを使えません。PINで保護できます',
                style: const TextStyle(
                    color: AppColors.textDim, fontSize: 12)),
            value: app.deviceLockEnabled && canToggleDeviceLock,
            onChanged: canToggleDeviceLock
                ? (on) => app.setDeviceLockEnabled(on)
                : null,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading:
                const Icon(Icons.timer_outlined, color: AppColors.accent),
            title: const Text('再ロックまでの時間'),
            subtitle: const Text('アプリを離れてからロックするまで',
                style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            trailing: Text(graceLabel(app.relockGraceMs),
                style: const TextStyle(color: AppColors.textDim)),
            onTap: _pickGrace,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.lock_outline, color: AppColors.accent),
            title: const Text('今すぐロック'),
            onTap: () => lockNowOrExplain(context, app),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: const Icon(Icons.pin_outlined, color: AppColors.accent),
            title: Text(app.hasPin ? 'PINを変更' : 'PINを設定'),
            subtitle: const Text('画面ロックの代わりに、PINでも解除できます',
                style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            trailing: app.hasPin
                ? TextButton(
                    onPressed: _removePin, child: const Text('解除'))
                : null,
            onTap: () => _editPin(isNew: !app.hasPin),
          ),
        ),
        const SizedBox(height: 8),
        // オフライン保存は接続なしでも見る・消すので、接続の有無に関わらず出す
        OfflineSettingsCard(app: app),
        if (app.connected) const SizedBox(height: 8),
        if (app.connected) Card(
          child: ListTile(
            leading: const Icon(Icons.link_off, color: AppColors.danger),
            title: const Text('切断',
                style: TextStyle(color: AppColors.danger)),
            subtitle: const Text('保存した接続情報を消去します',
                style: TextStyle(color: AppColors.textDim, fontSize: 12)),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('切断しますか？'),
                  content:
                      const Text('エンドポイントとトークンがこの端末から消えます。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('キャンセル')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('切断')),
                  ],
                ),
              );
              if (ok == true) await app.disconnect();
            },
          ),
        ),
        const SizedBox(height: 24),
        const Center(
          child: Text('R2 Gallery (Flutter) 0.1.0',
              style: TextStyle(color: AppColors.textDim, fontSize: 12)),
        ),
      ],
    );
  }
}
