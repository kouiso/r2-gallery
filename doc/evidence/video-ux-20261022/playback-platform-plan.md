# バックグラウンド再生・PiP・メディア操作の残作業

調査日: 2026-10-22。対象: [#196 バックグラウンド再生](https://github.com/kouiso/r2-gallery/issues/196)、[#197 PiP](https://github.com/kouiso/r2-gallery/issues/197)。両Issueの本文・完成条件を読み取りで確認した。

**バックグラウンド再生、OS標準PiP、OSのメディア操作は未実装。ここに記す構成・操作は提案であり、合格証跡ではない。** 今回のフッター、明るさ・音量、復帰時の認証判定の修正で、この2件を完了扱いにしない。画面スリープ防止は別の変更で、背景実行やPiPの許可にはならない。

## 現行コードで確認できた境界

- 配布対象はAGENTS.mdにあるAndroidのFlutter release APKと確認用Flutter Web。iOSディレクトリの存在を配布・対応の証拠にしない。
- `flutter/android/app/src/main/AndroidManifest.xml`のサービスは`TransferService`、種類は`dataSync`のみ。`FOREGROUND_SERVICE_MEDIA_PLAYBACK`、`mediaPlayback`サービス、`supportsPictureInPicture`宣言はない。
- `TransferService.kt`の通知・寿命管理はアップロードとダウンロード用。`SharedEngine.kt`も`TransferService.running`を基準に、画面が閉じた後のエンジン維持・破棄を決めている。これを動画再生の保証として流用できない。
- `VideoView`は画面のライフサイクルで停止する。今回追加した`AppState.foregroundSettled`待ちは、再ロック判定中の音漏れを防ぐためのもの。背景で再生する実装ではない。
- `pubspec.lock`は`video_player 2.14.1`、Android実装`2.12.2`、AVFoundation実装`2.12.1`、Web実装`2.4.0`。現在のコントローラ生成では背景再生オプションを有効にしていない。`allowBackgroundPlayback`の既定値もfalseである。[Flutter公式パッケージAPI](https://pub.dev/documentation/video_player/latest/video_player/VideoPlayerOptions-class.html)
- `flutter/ios/Runner/Info.plist`に`UIBackgroundModes`がなく、SceneDelegateは雛形。アプリ固有のAVAudioSession・PiPブリッジ、Now Playing連携は確認できない。
- 現在のFlutter UIにはPiP開始操作・入退出通知・MediaSession連携がない。Webの公開プラグインAPIも、今回確認した範囲ではPiP操作を提供していない。[Webプラグインの公開API](https://pub.dev/documentation/video_player_web/latest/video_player_web/)

## 対応表

| 対象 | プラットフォーム上の可否・条件 | 本アプリの現状 | 実装前に必要な確定事項 |
| --- | --- | --- | --- |
| Android 背景音声・メディア操作 | 再生用ServiceとMediaSessionを用いる構成が候補。現行の転送サービスとは責務が異なる | 未実装。アプリ切替で停止する既存方針を維持 | 再生器を所有するサービス、Flutterとの状態同期、対応SDK/端末、通知・音声フォーカス・認証制御 |
| Android PiP | OS APIはAndroid 8.0 / API 26以降。端末のPiP機能・ユーザー設定も確認が必要 | 未実装。Activity宣言・入退出ブリッジなし | 明示開始、非対応理由、同一プレイヤーのSurface引継ぎ、通常表示への復帰 |
| iOS 背景音声・メディア操作 | AVAudioSessionと背景音声設定、割込み・経路変更・Now Playing/Remote Commandの検討が必要 | 未提供・未検証。配布経路も未確立 | 製品としての最低OS、実機、署名・配布手順、背景モードと音声セッションの変更範囲 |
| iOS PiP | AVKitの実機能力判定が必要。APIの存在だけで全端末対応としない | 未提供・未実装・未検証 | AVPlayerとPiPコントローラの接続、delegate、復帰処理、対応OS/端末の確定 |
| Web 背景音声・メディア操作 | ブラウザ・OS・タブの状態で異なる。Media Session API自体は背景実行の保証ではない | 未実装。Webはアップロード・再生確認用 | 対象ブラウザ別の実測、停止・復帰仕様、メディア操作と認証の連携 |
| Web PiP | 標準APIの有無、ユーザー操作、ポリシー・動画の状態を実行時に確認 | 未実装。現在のFlutterコントローラからの接続も未整備 | 同じHTML video要素を操作するプラグイン側API、拒否理由表示、enter/leaveイベント、終了処理 |

AndroidのAPI条件と端末能力判定は[Android公式PiPガイド](https://developer.android.com/develop/ui/views/picture-in-picture)による。iOSの背景音声には[AVAudioSession playbackの設定](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback)が関係し、PiPは[AVPictureInPictureControllerの能力判定](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/ispictureinpicturesupported())を使う。iOSの製品最低OSは今回決めていない。

## Androidの実装候補と未着手部分

1. **再生を一つの所有者へ集約する。** 再生用サービスがPlayerとMediaSessionを持ち、Flutterは操作と表示の窓口にする候補を検証する。現在のvideo_playerが所有する再生器と別の再生器を同時に作らない。バックエンドの拡張方法、Surfaceの受渡し、オンライン/暗号化オフライン再生を含めた同一セッション性は未検証。
2. **再生状態を双方向で同期する。** 作品ID・接続スコープ・再生位置・再生/一時停止・終了・エラーを一元化し、通知/ヘッドセット/Flutter/PiPの操作を同じ経路へ送る。署名URLを恒久保存せず、認証後の再取得経路を残す。
3. **サービスの境界を実装する。** 再生終了、明示停止、Viewer終了、ログアウト、認証ロックでPlayer・MediaSession・通知・Surface・再生用一時ファイルを確実に解放する。`SharedEngine`の転送依存の寿命管理も見直す。単に`allowBackgroundPlayback=true`にするだけでは、この所有権・終了処理は得られない。
4. **音声割込みを扱う。** Media3/音声フォーカスを統合し、電話、他アプリの音声、イヤホン/Bluetooth切断、出力先変更で停止/減音/再開条件を定義する。手動停止を割込み復帰で勝手に再生へ変えない。[Android公式 音声フォーカス](https://developer.android.com/media/optimize/audio-focus)
5. **PiPの遷移を設計する。** 最初は明示開始を候補とし、自動開始は別途決める。Activityの小窓化でフッターや作品情報を出さず、動画だけを表示する。同一プレイヤーの位置と一時停止状態を通常表示へ戻し、元の一覧・選択・スクロールを失わせない。PiPを閉じた時は停止・解放する案を検証する。音声だけ継続したい場合は別の明示仕様が必要。

Android公式は再生用サービスの宣言・権限・解放を説明している。[MediaSessionServiceの公式構成](https://developer.android.com/media/media3/session/background-playback)

**今回の変更範囲では、再生用サービスの追加、`FOREGROUND_SERVICE_MEDIA_PLAYBACK`追加、ActivityのPiP設定変更は許可されていないため未着手。** `SYSTEM_ALERT_WINDOW`や任意オーバーレイ権限を代替に要求しない。Android SDK/Flutter SDKを使うビルド・実機検証も今回実施できていない。

## 認証・プライバシーと共通の状態遷移

- OSの画面オフ/端末ロックと、アプリ内認証ロックを別の状態として扱う。OSがロックされたことを認証解除と解釈しない。
- 背景再生を明示的に許可する場合も、認証ロック・ログアウト・接続スコープ変更・ライブラリ認可取消しでは即停止する。再ロック猶予を背景側でも適用する設計が必要。復帰時は最新の`foregroundSettled`判定後に再開可否を確認する。
- MediaSession/通知/ロック画面/外部コントローラへ作品名・画像・審査メモ・署名URLを無条件に公開しない。非公開メディアの表示方針と、外部コマンドの許可条件を先に決める。
- PiPから認証を回避して動画や一覧を表示しない。ロック時は小窓を閉じる/映像を隠す処理と、音声停止を同じ状態遷移で実行する。
- 暗号化オフライン動画を再生中だけ復号する方針を保つ。背景プレイヤーへ所有権を移す場合は、平文一時ファイルの寿命も移し、終了・認証取消し・異常終了後の掃除まで確認する。
- 画面スリープ防止は前面再生時だけの別制御。背景音声・PiP・Service維持の代替として扱わない。

## Webは別の実装・検証表を持つ

WebはAndroidのActivity設定やServiceを流用できない。同じvideo要素へのプラグイン側の窓口を設け、`requestPictureInPicture()`、`exitPictureInPicture()`、入退出イベントと拒否を扱う案を検証する。標準ではユーザー操作を要求する場合があり、ポリシーによる拒否も定義されている。ブラウザ側のPiP開始/終了やタブ非表示を、Flutterの画面破棄と誤認して二重再生させない。[W3C PiP仕様（作業草案）](https://w3c.github.io/picture-in-picture/)

`navigator.mediaSession`の操作・再生状態・位置更新はPiPと別に検証する。認証ロックや終了時にaction handler・metadata・position stateを解除する。Media Session APIの対応だけで、モバイルブラウザの画面オフ継続を合格扱いにしない。[W3C Media Session仕様（作業草案）](https://www.w3.org/TR/mediasession/)

Chrome/Edgeのデスクトップ、SafariのmacOS/iOS、Androidの対象ブラウザを分け、APIの有無、PiP許可、バックグラウンド/画面オフ、音声割込みを記録する。未対応・拒否時は理由を表示して通常再生へ戻す。ブラウザ互換性は今回未検証で、上記全環境で利用できるとは述べない。

## 受入操作と残る証跡

以下はすべて**未実施**。合成動画を使い、OS/ブラウザ版・端末・アプリ版/commit・動画形式/長さ・開始位置・操作時刻・期待値・実測結果・終了後リソースを記録する。既存のCompose画像やフッターの静止画を、この受入証跡として代用しない。

| 系列 | 具体的な操作 | 合格条件 |
| --- | --- | --- |
| 背景再生 | 30秒位置で再生→他アプリを操作→30秒後に戻る | 許可した環境では音声と位置が連続し、映像が追従。再生成・先頭戻り・二重音声なし |
| OSロック | 再生→画面オフ/端末ロック→解除→アプリ復帰 | 定義した背景許可と猶予を守る。復帰の認証判定前に勝手な音声・映像を出さない |
| 一時停止 | 一時停止→アプリ切替・OSロック→戻る | 一時停止状態・位置を保持し、自動再生しない |
| OSメディア操作 | 通知/ロック画面/ヘッドセットから再生・停止・シーク | 同一セッションへ反映。非公開情報を出さず、認証取消し後の操作を拒否 |
| PiP一巡 | 明示開始→別アプリ操作→小窓の再生/停止→通常表示へ戻る | 映像・音声・位置・停止状態を共有し、元画面へ戻れる |
| PiP終了 | PiPを閉じる→通知/プレイヤー/音声/一時ファイルを確認 | 定義した停止方針で終了し、裏に再生器や平文が残らない |
| 認証境界 | 背景/PiP中に認証ロック・接続切替・ログアウト・認可取消し | 即時停止・映像非表示・外部操作無効・一時ファイル解放 |
| 再復帰競合 | 端末認証問い合わせを遅らせ、背景→復帰→背景→復帰 | 最新のロック判定まで待ち、古い復帰完了による再生をしない |
| 割込み | 電話・他音声・ヘッドセット切断・Bluetooth切替 | 方針どおり停止/減音し、手動停止を勝手に解除しない |
| 非通常状態 | 未読込・バッファ中・失敗・終了・一時停止でPiP操作 | クラッシュ・二重生成・勝手な再生なし。拒否理由が分かる |
| 許可・OS制約 | PiP無効/非対応、サービス停止、タスク除去、強制停止 | 安全に通常表示/停止へ戻る。OSが禁じる継続は保証しない |
| 回帰 | 画像・通常動画・ライブラリ切替・アップロード/取り込み | 既存機能を保ち、転送終了で再生器が壊れない/再生終了で転送が止まらない |

音声・位置の連続、他アプリ操作、PiP入退出、OSロック前後を確認できる動画が必要。画面録画で収録できない状態は外部撮影等で補い、不可能な部分は未確認と記録する。実データ移行、iOS実機、配布後の確認は別の未検証事項として残す。

この調査ではIssue更新・外部連絡・権限/OS設定変更・CI明示起動・merge・本番配布を行っていない。
