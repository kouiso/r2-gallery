// 画面に出たことだけで済ませず、手元の Worker の中身でも確かめる。
// WORKER と TOKEN は maestro test -e で渡す（CI の手元 Worker の確認用の値で、本番ではない）
var headers = { headers: { Authorization: 'Bearer ' + TOKEN } };

function keysIn(path, field) {
  var res = http.get(WORKER + path, headers);
  if (res.status !== 200) throw new Error(path + ' -> ' + res.status);
  return json(res.body)[field].map(function (it) { return it.key; });
}

var root = keysIn('/v1/a/folders?prefix=', 'items');
var trash = keysIn('/v1/a/trash', 'items');
var ok;
if (CHECK === 'uploaded') {
  ok = root.indexOf('maestro-upload.jpg') >= 0;
} else if (CHECK === 'trashed') {
  ok = root.indexOf('seed-photo.jpg') < 0 &&
    trash.indexOf('seed-photo.jpg') >= 0;
} else if (CHECK === 'restored') {
  ok = root.indexOf('seed-photo.jpg') >= 0 && trash.length === 0;
} else if (CHECK === 'heic') {
  var res = http.get(WORKER + '/v1/a/folders?prefix=', headers);
  if (res.status !== 200) throw new Error('/v1/a/folders -> ' + res.status);
  var items = json(res.body).items;
  var heic = items.find(function (it) { return it.key === 'seed-photo.heic'; });
  ok = !!heic && heic.thumbStored === true;
} else {
  throw new Error('unknown CHECK: ' + CHECK);
}
console.log('check ' + CHECK + ': ' + ok + ' root=' + JSON.stringify(root) + ' trash=' + JSON.stringify(trash));
output.check = ok;
