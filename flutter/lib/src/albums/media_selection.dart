import '../api/models.dart';
import '../state/app_state.dart';

/// アルバム・フォルダ画面の選択。アルバムはライブラリが混ざるので、キーだけでなく lib と組で持つ。
class MediaSelection {
  final Map<SelKey, MediaItem> _picked = {};

  bool get isEmpty => _picked.isEmpty;
  bool get isNotEmpty => _picked.isNotEmpty;
  int get length => _picked.length;
  List<MediaItem> get items => _picked.values.toList();

  bool contains(MediaItem it, String fallbackLib) =>
      _picked.containsKey(SelKey(it.lib ?? fallbackLib, it.key));

  void toggle(MediaItem it, String fallbackLib) {
    final k = SelKey(it.lib ?? fallbackLib, it.key);
    if (_picked.remove(k) == null) _picked[k] = it;
  }

  /// 見えている全件が選ばれているか。件数だけで比べると、取り直しで消えた古い選択に騙される
  bool allSelected(List<MediaItem> visible, String fallbackLib) =>
      visible.isNotEmpty && visible.every((it) => contains(it, fallbackLib));

  /// 全部選ばれていれば外し、そうでなければ全部足す。日ごとの丸と「すべて選択」で共用する。
  void toggleAll(List<MediaItem> visible, String fallbackLib) {
    if (allSelected(visible, fallbackLib)) {
      for (final it in visible) {
        _picked.remove(SelKey(it.lib ?? fallbackLib, it.key));
      }
    } else {
      for (final it in visible) {
        _picked[SelKey(it.lib ?? fallbackLib, it.key)] = it;
      }
    }
  }

  void clear() => _picked.clear();
}
