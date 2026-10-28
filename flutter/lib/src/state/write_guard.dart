import '../api/models.dart';
import 'app_state.dart';

/// 書き込みの種類。読み取り専用の時に出す文言が KMP 版で操作ごとに違うので分ける。
enum WriteAction {
  /// 端末からのアップロード
  upload,

  /// 取り込み（ネットから）の保存
  save,

  /// ゴミ箱へ移す
  trash,

  /// ゴミ箱から戻す
  restore,

  /// アルバムの作成・追加・削除、移動・コピー、フォルダ作成、サムネ書き戻しなどその他
  edit,
}

/// 書き込めない理由。書き込める時だけ null。
///
/// 一覧に無い（未取得・外れた）ライブラリは、読み取り専用かどうか分からないので書き込ませない。
/// Worker に 403 で弾かれて、同じ失敗を繰り返すのを入口で止めるため（KMP 版 canWriteTo と同じ）。
String? writeBlockMessage({
  required bool connected,
  required List<Library> libraries,
  required String? lib,
  required WriteAction action,
}) {
  if (!connected) return '保存先が未接続です。';
  Library? found;
  for (final l in libraries) {
    if (l.id == lib) {
      found = l;
      break;
    }
  }
  if (lib == null || found == null) {
    return '接続先にライブラリが見つかりません。接続先と権限を確認してください。';
  }
  if (!found.readOnly) return null;
  return switch (action) {
    WriteAction.upload => 'このライブラリは読み取り専用なので、アップロードできません。',
    WriteAction.save => 'このライブラリは読み取り専用なので、保存できません。',
    WriteAction.restore => 'このライブラリは読み取り専用のため、戻せません',
    WriteAction.trash || WriteAction.edit => 'このライブラリは読み取り専用です',
  };
}

/// どのグループの書き込み経路も、API を叩く前にここを通す。
/// 判定材料（接続とライブラリ一覧）は AppState だけが持つので、AppState に生やす。
extension WriteGuard on AppState {
  String? writeBlock(String? lib, WriteAction action) => writeBlockMessage(
    connected: connected,
    libraries: libraries,
    lib: lib,
    action: action,
  );

  bool canWriteTo(String? lib) => writeBlock(lib, WriteAction.edit) == null;

  /// 表示用。一覧に無いライブラリは読み取り専用扱いにはしない（鍵を付けると誤解を招く）。
  bool isReadOnlyLib(String? lib) =>
      libraries.any((l) => l.id == lib && l.readOnly);
}
