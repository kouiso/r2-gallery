#!/bin/bash
# リポジトリの commonMain から「画面の見た目だけ」の部品を harness にコピーする
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$ROOT/kmp/composeApp/src/commonMain/kotlin/app/r2gallery
DST=$(dirname "$0")/src/main/kotlin/app/r2gallery
rm -rf "$DST"; mkdir -p "$DST"/{theme,model,vm,ui,lock,queue,api}
for f in theme/Theme.kt model/Models.kt model/Retention.kt vm/GalleryModels.kt \
  ui/BulkTrash.kt ui/DayLabel.kt ui/MediaGrid.kt ui/GalleryParts.kt ui/StateViews.kt \
  ui/SelectionBar.kt ui/BottomTabs.kt ui/HomeContent.kt ui/AlbumsTabContent.kt ui/ViewerParts.kt ui/Format.kt ui/TransfersParts.kt ui/TrashParts.kt queue/TransferModels.kt ui/SettingsContent.kt ui/GateContent.kt ui/UploadConfirm.kt ui/ImportParts.kt $EXTRA; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DST/$f" || echo "skip $f"
done
cat > "$DST/lock/Time.kt" <<'K'
package app.r2gallery.lock
fun currentTimeMillis(): Long = System.currentTimeMillis()
K
# TransferModels が参照する型だけ（本物は ApiClient.kt にあり、通信に依存するのでコピーしない）
cat > "$DST/api/MultipartPart.kt" <<'K'
package app.r2gallery.api
data class MultipartPart(val partNumber: Int, val etag: String)
K
