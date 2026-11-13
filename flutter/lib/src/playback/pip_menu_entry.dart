import 'package:flutter/material.dart';

import 'playback_session.dart';

/// 小窓ボタンの置き場所はここ 1 か所だけ。⋮「再生方法」メニューの中に置いている。
/// 操作バーへ動かす時は、この部品を差し替えるだけで済むようにしている。
class PipMenuEntry extends StatelessWidget {
  const PipMenuEntry({
    super.key,
    required this.session,
    required this.surfaceKey,
    required this.sheetContext,
    required this.parentContext,
  });
  final PlaybackSession session;
  final GlobalKey surfaceKey;

  /// メニューのシート。入る前に畳む。
  final BuildContext sheetContext;

  /// スナックバーを出す側。シートが畳まれた後も生きている。
  final BuildContext parentContext;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.picture_in_picture_alt),
    title: const Text('小窓で再生'),
    subtitle: Text(
      session.pipSupported ? '同じ再生位置のまま、他のアプリに重ねて表示します' : 'この端末では小窓再生を利用できません',
    ),
    onTap: session.closed || !session.pipSupported
        ? null
        : () async {
            final render = surfaceKey.currentContext?.findRenderObject();
            if (render is! RenderBox || !render.hasSize) return;
            final rect = render.localToGlobal(Offset.zero) & render.size;
            Navigator.of(sheetContext).pop();
            await WidgetsBinding.instance.endOfFrame;
            final accepted = await session.enterPip(rect);
            if (!accepted && parentContext.mounted) {
              ScaffoldMessenger.of(parentContext).showSnackBar(
                SnackBar(
                  content: Text(session.message ?? '小窓を開始できませんでした'),
                  // 許可が無い時は理由だけでなく次の一手も出す
                  action: session.pipSettingsNeeded
                      ? SnackBarAction(
                          label: '設定を開く',
                          onPressed: session.openPipSettings,
                        )
                      : null,
                ),
              );
            }
          },
  );
}
