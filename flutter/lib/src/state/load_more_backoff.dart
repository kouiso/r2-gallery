/// 続きの取得に失敗した後の待ち時間の上限（#181）。圏外が長く続いても
/// 1分に1回以下に留める。
const loadMoreBackoffCap = Duration(seconds: 60);

/// 続けて [failures] 回失敗した後に空ける時間。0回なら0。
/// base, base*2, base*4 … で loadMoreBackoffCap を超えない。
Duration loadMoreBackoffAfter(Duration base, int failures) {
  if (failures <= 0) return Duration.zero;
  var wait = base;
  for (var i = 1; i < failures; i++) {
    final next = wait * 2;
    if (next >= loadMoreBackoffCap) return loadMoreBackoffCap;
    wait = next;
  }
  return wait > loadMoreBackoffCap ? loadMoreBackoffCap : wait;
}
