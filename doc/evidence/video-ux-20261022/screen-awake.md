# 前景の動画再生中だけ画面を保持する

実装済み、Flutter/Dart の型検査とテスト、Web/Android の実再生は未実行。設定公開後に承認された同一公式 manifest URLへの1回の確認も403だった
（[最新結果](flutter-manifest-after-publish.txt)）。以後の取得・迂回は行っていない。
Chromium の通常 sandbox 起動失敗も回避していない。本書の状態遷移はコードとテスト設計であり、端末の消灯試験が通ったという証跡ではない。

## 共通の条件と所有権

`PlaybackScreenAwake(controller, active, child)` をネット動画の VideoView と保存動画の OfflineViewer に接続する。VideoPlayerController の値、Flutter の lifecycle、AppLockScope を監視し、次の条件をすべて満たす時だけ要求する。

- 前景（resumed）で、現在表示する動画である。
- 初期化済み、isPlaying が true、完了とエラーのいずれでもない。
- アプリがロックされていない。

isPlaying が true のまま一時的にバッファ待ちとなる場合は、視聴中なので保持を続ける。pause、end、error、active=false、アプリロック、退出、inactive/hidden/paused/detached で要求を外す。画面内の「操作ロック」はアプリの PIN ロックとは異なり、再生中の保持を外さない。

`ScreenAwakeCoordinator` は窓ごとの共有インスタンスで、各画面が lease を持つ。要求をまとめ、取得と解放を順番に行うため、古い動画画面の dispose が新しい動画の保持を消さない。未実行の要求はまとめ、動画の位置更新ごとに OS/ブラウザへ問い合わせない。取得待ちの間に pause/退出した場合、遅れて取得できても直ちに解放する。

公開 API:

```dart
PlaybackScreenAwake(
  controller: video,
  active: foreground && authorized,
  child: existingVideoWidget,
)
```

`coordinator:` はテストで driver を代役にする口。`onStatusChanged:` から状態を受け取れる。保持を必要としない UI や画像に対しては使用しない。

## Android

既存 `app.r2gallery/player` MethodChannel の `setKeepScreenOn(true/false)` で、現在の Activity の窓に `FLAG_KEEP_SCREEN_ON` を設定・解除する。MainActivity が前景でない時は取得を拒否し、onPause/onStop でも必ずフラグを外す。onResume 自体はフラグを付け直さず、Dart 側で前景の再生条件が満たされた要求を待つ。

新しい permission、CPU WakeLock、グローバルの画面タイムアウト・明るさ設定、Keyguard の解除、画面を再点灯させるフラグは追加していない。手動の電源ボタンや OS のロックを無効化しない。

公式の窓単位 API: [Keep the screen on](https://developer.android.com/develop/background-work/background-tasks/awake/screen-on)。OS が背景画面の消灯を許すことに加え、アプリ側でも状態の終了時に clearFlags を行う。

## Web

`dart.library.js_interop` の conditional import で Web 専用 driver を選ぶ。ネイティブのビルドに DOM/JS の実装を読み込ませない。

- secure context と navigator.wakeLock の有無を確認する。
- 表示中の文書から `request('screen')` し、返された sentinel を保持する。
- 文書の visibilitychange と sentinel の release を監視する。
- sentinel は一度解放されたら再利用せず、再生を継続する条件で可視化した時に新しい要求を出す。
- OS・利用者による release の直後は即座に取り返さず、表示復帰または pause→play の機会まで待つ。
- unsupported（API が無い/安全なコンテキストでない）、denied（ブラウザの要求拒否）、released（解放済み）、acquiring、held、failed を区別する。拒否を取得成功として扱わず、進捗通知による無限リトライをしない。
- release の Promise が失敗した時は failed とし、解放成功を保証しない。sentinel の参照は捨てず、Coordinator にも held と別の releasePending（保持不明）を残す。明示的 release、画面や Coordinator の終了時には再解放し、同じ false の進捗通知では連打しない。新しい再生要求の取得は妨げず、その取得が成功すれば保持不明を解消する。Android の通信失敗も failed とし、native の onPause/onStop の解除を補助境界にする。

ブラウザ自身の電池・利用者設定・Permissions Policy による拒否に従う。サーバーの policy/header や iframe 設定を緩和して成立させる変更はない。ページが非表示になれば保持の要求も外すため、電源ボタンでの画面ロックを妨げる機能ではない。

一次資料: [W3C Screen Wake Lock（現在の Working Draft）](https://www.w3.org/TR/screen-wake-lock/)。release と visibilitychange に応じて新たな sentinel を要求する設計に従う。

## iOS/macOS と既存 plugin

今回の独自 driver は Android/Web 向けで、iOS/macOS の native driver は unsupported を返す。既存 video_player の既定の画面保持オプションは変更しない。

調査中に `VideoPlayerOptions.preventsDisplaySleepDuringVideoPlayback` を検討したが、[公式 changelog](https://pub.dev/packages/video_player/changelog) は 2.13.0 で追加し、iOS/macOS の挙動を制御すると明記している。lock の video_player 2.14.1 と platform_interface 6.9.0 に該当する API は公開されているが、これを全プラットフォームで false にすると iOS の既存機能を落とし得るため採用していない。依存関係の更新もない。

背景再生・ロック画面のメディア操作・PiP の追加ではない。#196/#197 は別の未実装項目のまま。

## 追加した回帰テスト（未実行）

`flutter/test/screen_awake_test.dart` に 18 ケース（parameterized を展開した数）を追加した。

- 要求の反復通知で取得を連打しない。
- unsupported / denied / failed をそれぞれ区別する。
- OS release 後の待機、非表示→表示での再取得、pause 中の可視化では再取得しない。
- 取得待ち中の退出、画面同士の要求引継ぎ、遅い古い解放と新取得の順序。
- release 失敗後の状態、次の再生要求を取り残さないこと、停止中に連打せず dispose で保持不明分を再解放すること。
- 前景・初期化・play の条件、視聴中の buffering 継続、pause/end/error/退出での解放。
- lifecycle paused（手動電源ロックに相当する状態通知）での解放と前景復帰。
- 裏の動画とアプリロック中の保持禁止。
- VideoView の実装を経由した pause/play/退出。
- Android の既存チャネルの true/false、MissingPlugin と拒否の識別。

```sh
cd flutter
flutter test test/screen_awake_test.dart test/video_view_test.dart test/offline_privacy_test.dart
flutter analyze
flutter build web --release
```

ここでは SDK が無いため、上記は**未実行**。特に JS interop のコンパイル、実際の wakeLock Promise と visibilitychange、Android の窓フラグ、保存動画への接続、手動電源ボタンは、対応環境で追加確認が必要。`git diff --check` の成功だけを Flutter の型検査・テスト成功とは数えない。

実機/ブラウザで必要な操作: 再生中に自動消灯の待ち時間を超える→一時停止→終了→エラー→戻る→他アプリへ移る→手動電源ロック→復帰→アプリの即時ロック。Web は API 未対応、要求拒否、OS release、表示復帰時の再取得も確認し、保持を許さない環境で通常の動画操作が使えることを確認する。
