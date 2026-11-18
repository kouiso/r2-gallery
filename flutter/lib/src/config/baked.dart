/// ビルド時に --dart-define で埋め込む接続先。KMP 版の BAKED_ENDPOINT/BAKED_TOKEN と同じ役目で、
/// 初回起動を設定ゼロで繋ぐために要る（これが無いと上書き更新した利用者がトークン入力で詰まる）。
/// Web ビルドには渡さない前提（Pages の静的ファイルにトークンを載せないため）。
const bakedEndpoint = String.fromEnvironment('R2_BAKED_ENDPOINT');
const bakedToken = String.fromEnvironment('R2_BAKED_TOKEN');

/// 検証ビルドだけ端末ロックを外す dart-define。画面ロック/生体の無いエミュレータの
/// E2E lane では LockGate が開けず、FLAG_SECURE で録画も真っ黒になるため。
/// 製品ビルドには渡さない前提（渡さなければ既定OFF）。
const disableLockForTesting = bool.fromEnvironment('R2_DISABLE_LOCK');
