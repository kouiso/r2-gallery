# r2_gallery (Flutter client)

R2 Gallery の Flutter クライアント（Android APK と Web ビルド）。プロジェクト全体の説明・
ビルドと配布の手順は、リポジトリルートの
[README.md](../README.md) と [CLAUDE.md](../CLAUDE.md) を見る。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release   # 配布用（AOT）。debug ビルドは配らない
flutter build web --release
```

- 接続先とトークンは接続画面から入れるか、ビルド時に `--dart-define=R2_BAKED_ENDPOINT=...`
  `--dart-define=R2_BAKED_TOKEN=...` で焼き込む（`lib/src/config/baked.dart`）。
- 機能の対応は [`../doc/feature-parity.md`](../doc/feature-parity.md)。
