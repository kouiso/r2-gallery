/// ビルド時に --dart-define で埋め込む接続先。KMP 版の BAKED_ENDPOINT/BAKED_TOKEN と同じ役目で、
/// 初回起動を設定ゼロで繋ぐために要る（これが無いと上書き更新した利用者がトークン入力で詰まる）。
/// Web ビルドには渡さない前提（Pages の静的ファイルにトークンを載せないため）。
const bakedEndpoint = String.fromEnvironment('R2_BAKED_ENDPOINT');
const bakedToken = String.fromEnvironment('R2_BAKED_TOKEN');
