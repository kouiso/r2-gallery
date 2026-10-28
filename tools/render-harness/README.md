# render-harness

実機・エミュレータが無い環境で、画面の見た目だけの部品（`*Content.kt`・`SelectionBar`・
`BottomTabs`・`MediaGrid` など）を **実際のソースのまま** PNG に描き出す確認用ツール。
アプリのビルドには含まれない。

## 使い方

```sh
cd tools/render-harness
./sync.sh                        # kmp の部品を src/main/kotlin/app/ にコピー（git管理外）
gradle render -Pout=out          # 全シーン × 4サイズ。第2引数で絞れる: -Pout=out の後ろに接頭辞
```

- 描画は Compose Desktop（Skia）。幅 320/390/412dp、文字倍率 1.0/1.3 の組み合わせを出す。
- 写真の代わりに色グラデーションの合成画像を使う（実写真は載せない）。

## 限界（証跡として言えること・言えないこと）

- **言える**: 幅の狭い端末・大きい文字でレイアウトが崩れないか、ラベルが消えないか、
  選択・空・エラーの見た目が仕様どおりか。
- **言えない**: 実機のフォント（Android は Roboto/Noto Sans CJK、ここは DejaVu/IPA）での
  文字幅の差、ステータスバー・ジェスチャーバー、権限ダイアログ、実通信、動画再生。
  これらは実機で確認する。
- ViewModel・ナビゲーション・Dialog/BottomSheet は描かない（状態を持つ側は単体テストで見る）。
