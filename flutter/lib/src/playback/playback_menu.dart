import 'dart:async';

import 'package:flutter/material.dart';

import 'pip_menu_entry.dart';
import 'playback_session.dart';

class PlaybackMenu extends StatelessWidget {
  const PlaybackMenu({
    super.key,
    required this.session,
    required this.surfaceKey,
  });
  final PlaybackSession session;
  final GlobalKey surfaceKey;

  Future<void> _open(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: session,
            builder: (_, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('再生方法', style: TextStyle(fontSize: 18)),
                ),
                SwitchListTile(
                  title: const Text('バックグラウンド再生'),
                  subtitle: Text(
                    session.backgroundSupported
                        ? '他のアプリや画面オフでも、この動画を再生します'
                        : 'この環境では利用できません',
                  ),
                  value: session.backgroundAllowed,
                  onChanged: session.closed || !session.backgroundSupported
                      ? null
                      : (value) =>
                            unawaited(session.setBackgroundAllowed(value)),
                ),
                PipMenuEntry(
                  session: session,
                  surfaceKey: surfaceKey,
                  sheetContext: sheet,
                  parentContext: context,
                ),
                ListTile(
                  leading: const Icon(Icons.stop_circle_outlined),
                  title: const Text('再生を終了'),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(session.stop());
                  },
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text('アプリの再ロック・接続変更で停止します。通知やロック画面には作品名を表示しません。'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '再生方法',
    icon: const Icon(Icons.more_vert),
    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    onPressed: session.closed ? null : () => _open(context),
  );
}
