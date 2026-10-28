import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'theme.dart';

/// 起動やライブラリ取得に失敗した時に上へ出す帯。理由と「再試行」「閉じる」を出す。
/// 失敗を黙ると、空の画面やスピナーのまま固まったように見えるため（KMP 版 initError と同じ）。
/// Navigator の中（home）に置くので、ロック中はロックの層に隠れる。
class StartupErrorBanner extends StatelessWidget {
  final AppState app;
  final Widget child;
  const StartupErrorBanner({super.key, required this.app, required this.child});

  @override
  Widget build(BuildContext context) {
    final msg = app.startupError;
    // 帯の出し入れで下の画面（タブや一覧）の状態を作り直さんよう、木の形は変えずに鍵で繋ぎ留める
    return Column(
      children: [
        if (msg != null)
          Material(
            color: AppColors.danger.withValues(alpha: 0.18),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '初期化に失敗: $msg',
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: app.retryStartup,
                      child: const Text('再試行'),
                    ),
                    IconButton(
                      tooltip: '閉じる',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: app.dismissStartupError,
                    ),
                  ],
                ),
              ),
            ),
          ),
        // 帯がステータスバー分の余白を取るので、下の画面には同じ余白を二重に取らせない
        Expanded(
          key: const ValueKey('startup-banner-content'),
          child: MediaQuery.removePadding(
            context: context,
            removeTop: msg != null,
            child: child,
          ),
        ),
      ],
    );
  }
}
