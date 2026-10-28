import 'package:flutter/material.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// ライブラリ切替の1件分の表示。読み取り専用には鍵を付け、選ぶ前に書けないと分かるようにする。
class LibraryLabel extends StatelessWidget {
  final Library library;
  const LibraryLabel({super.key, required this.library});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (library.readOnly) ...[
          const Icon(Icons.lock, size: 14, semanticLabel: '読み取り専用'),
          const SizedBox(width: 4),
        ],
        Text(library.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

/// 接続済みでも開くライブラリが決まっていない時の表示。
/// 取得中はスピナー、取れなかった・一つも無い時は理由と「再試行」を出す（固まって見せない）。
class NoLibraryView extends StatelessWidget {
  final AppState app;
  const NoLibraryView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    if (app.librariesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 56, color: AppColors.textDim),
            const SizedBox(height: 16),
            const Text(
              '接続先にライブラリが見つかりません。接続先と権限を確認してください。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textDim),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: app.retryStartup,
              child: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }
}
