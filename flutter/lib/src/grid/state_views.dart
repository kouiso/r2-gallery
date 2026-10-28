import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// 空・エラーの共通レイアウト（KMP 版 StateView）。
/// 「赤い文字だけ」にせず、何が起きたか＋次に押すものを必ず出す。文字を大きくしても切れんよう縦スクロールにする。
class StateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Color iconColor;
  final List<Widget> actions;
  const StateView({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.iconColor = AppColors.textDim,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: AppColors.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: iconColor),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            if (body != null) ...[
              const SizedBox(height: 16),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textDim),
              ),
            ],
            const SizedBox(height: 16),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 状態画面の主ボタン（高さ48以上）。
class StatePrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const StatePrimaryButton(this.label, this.onPressed, {super.key});
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: FilledButton(onPressed: onPressed, child: Text(label)),
  );
}

class StateTextButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const StateTextButton(this.label, this.onPressed, {super.key});
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: TextButton(onPressed: onPressed, child: Text(label)),
  );
}

/// 一覧が出ている状態で更新だけ失敗した時の細い帯。一覧は残したまま知らせる。
class ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ErrorBanner({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  message,
                  style: const TextStyle(color: AppColors.danger, fontSize: 12),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: TextButton(onPressed: onRetry, child: const Text('再試行')),
            ),
          ],
        ),
      ),
    );
  }
}
