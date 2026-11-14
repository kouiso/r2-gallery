# R2 Gallery: 同じ AVPlayer を使う PiP の接続

元は Flutter Authors の `video_player_avfoundation 2.12.1`（BSD-3-Clause）。
LICENSE、native runtime、Dart実装は同梱し、元の各ファイルhashを `upstream-files.json` に保存した。
example・upstream test harness・pigeonの再生成用入力はアプリ配布に使わないためコピーしていない。

変更は3ファイルのみ。VideoPlayerPluginに既存playerを返す口とtexture layerの接続切替を追加し、
FVPTextureBasedVideoPlayerのheader/実装に切替メソッドを追加する。
player生成・再生・seek・dispose・codec・HTTP処理・パッケージのDart APIは変更しない。

アプリ側のPiPはこの同じAVPlayerへAVPlayerLayerを接続する。背景音声ではtextureの非表示layerを外し、
通常表示へ戻る時に再接続する。別のAVPlayerを作らず、positionと手動pauseを維持する。
更新時は元版との差分を確認し、iOSのnative build・実機検証を行う必要がある。
