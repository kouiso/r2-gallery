import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../config/baked.dart' as baked;
import '../grid/photos_chrome.dart';
import '../offline/offline_store.dart';
import '../store/device_auth.dart';
import '../store/kv.dart';
import '../store/lock_platform.dart';
import '../store/lock_policy.dart';
import '../store/pin.dart';
import '../transfer/transfer_api.dart';
import '../transfer/transfer_platform.dart';
import '../transfer/transfer_queue.dart';
import '../upload/thumbs.dart';
import '../viewer/device_export.dart';
import '../webdl/cookies.dart';
import '../webdl/web_fetcher.dart';
import '../webdl/web_transfer.dart';
import 'write_guard.dart';
import 'pairing.dart';
import 'trash_ops.dart';

/// 端末の画面ロックの有無の問い合わせ結果。unknown は「確かめられなかった」で、
/// 無いとは扱わない（ロックを外したり抜け道を出したりしない）。
enum DeviceLockProbe { unknown, available, unavailable }

/// 接続状態とアプリ全体の導線を持つ状態。画面ツリーはこれを watch する。
class AppState extends ChangeNotifier {
  AppState({
    ApiClient? api,
    this.bakedEndpoint = baked.bakedEndpoint,
    this.bakedToken = baked.bakedToken,
    DeviceAuth? deviceAuth,
    LockClock? clock,
    bool? isWeb,
    TransferPlatform? transferPlatform,
    OfflineStore? offline,
  })  : api = api ?? ApiClient(),
        offline = offline ?? OfflineStore(),
        transferPlatform = transferPlatform ?? PlatformTransferBridge(),
        deviceAuth = deviceAuth ?? LocalDeviceAuth(),
        _clock = clock ?? PlatformLockClock(),
        _isWeb = isWeb ?? kIsWeb;

  final ApiClient api;
  final String bakedEndpoint;
  final String bakedToken;
  final DeviceAuth deviceAuth;
  final LockClock _clock;
  final bool _isWeb;

  /// 埋め込みの接続先で繋げなかった時に接続画面で理由を出すための印。
  bool bakedProbeFailed = false;

  // 起動を固まらせないための上限。KMP 版の PROBE_BUDGET_MS と同じ考え方。
  static const _bakedProbeBudget = Duration(seconds: 8);
  // 一部端末では認証可否の問い合わせが固まるので、起動を待たせない上限
  static const _authProbeBudget = Duration(seconds: 3);
  // 鍵ストアの読み出しなどが固まっても、読み込み中のまま止めない上限（KMP 版 INIT_BUDGET_MS）
  static const _initBudget = Duration(seconds: 20);

  /// 接続画面で「接続せずに取り込みだけ使う」を選んだ。保存はしない（KMP 版 browseOnly と同じ）。
  bool browseOnly = false;

  /// 起動やライブラリ取得の失敗。上部のバナーで理由と再試行を出す（黙って空の画面にしない）。
  String? startupError;

  /// ライブラリ一覧を取りに行っている最中か。空の一覧と「まだ来ていない」を見分けるため。
  bool librariesLoading = false;

  /// 接続済みか、接続なしでの利用を選んだか。ロックや窓の保護はこの間ずっと効かせる。
  bool get sessionOpen => connected || browseOnly;

  bool loading = true;
  bool connected = false;
  bool locked = false;
  bool hasPin = false;

  /// 端末の画面ロックで守るか（既定ON。KMP版 deviceLockEnabled と同じ）。
  bool deviceLockEnabled = true;

  /// 端末の画面ロック/生体の問い合わせ結果。web では unavailable になる。
  DeviceLockProbe deviceLockProbe = DeviceLockProbe.unknown;

  /// 端末に使える画面ロック/生体があると確かめられたか。
  bool get deviceLockAvailable => deviceLockProbe == DeviceLockProbe.available;

  /// ロック画面で端末認証を試させるか。確かめられなかった時も試させる（無いと決めつけない）。
  bool get deviceUnlockOffered =>
      !_isWeb && deviceLockProbe != DeviceLockProbe.unavailable;

  int relockGraceMs = relockGraceDefaultMs;

  /// 認証ダイアログ表示中。ダイアログが出す一時停止/復帰を「バックグラウンドに行った」と数えないための印。
  bool authenticating = false;
  Future<ClockReading>? _backgroundedAt;
  bool _backgroundedDuringExternal = false;
  bool _screenDetached = false;
  int _externalActivities = 0;

  List<Library> libraries = [];
  String? activeLib;

  /// 写真タブの並び順と選択ヘッダー。上のアプリバーと下の操作バーはシェルが描くので、
  /// 写真タブの中身とシェルの間をここでつなぐ。
  final PhotosChrome photosChrome = PhotosChrome();



  /// ネット取り込みのキュー。タブを離れても、PINでロックされても取り込みを続けるため、
  /// 画面ではなくここが持つ（KMP 版もキューは ViewModel 側にあった）。
  late final WebTransferQueue webQueue = WebTransferQueue(
    api: api,
    makeThumb: thumbFromFile,
    // 取得時の Cookie は送り先ごとに内蔵ブラウザから引き直す（別ホストへ漏らさない）
    fetcher: WebFetcher(cookieFor: webViewCookieFor),
    // アプリを消されても次の起動で続きから取り込めるよう、進み具合と一時ファイルを残す。
    // Web 版は内蔵ブラウザが無く取り込み自体を使わない
    ledger: kIsWeb ? null : const KvWebLedgerStore(),
    persistentStageDir: kIsWeb ? null : WebTransferQueue.defaultStageDir,
  );

  /// 転送を裏でも続けるサービスと回線の知らせ。
  final TransferPlatform transferPlatform;

  /// 端末に暗号化して置くオフライン保存。
  final OfflineStore offline;

  /// アップロードとオフライン保存のキュー。画面ではなくここが持ち、ロック中も裏で続ける。
  late final TransferQueue transfers = TransferQueue(
    api: ApiClientTransferApi(api),
    offline: offline,
    makeThumb: thumbFromFile,
    configured: () => api.conn != null,
  );

  // 写真タブは IndexedStack で生き続けて一覧を持ち続ける。ゴミ箱から戻すなど写真タブの外で中身が
  // 変わった時に知らせんと、戻した写真がアプリを開き直すまで写真タブに出ない
  final StreamController<String> _contentChanged =
      StreamController<String>.broadcast();

  /// 写真タブの外で中身が変わったライブラリ。
  Stream<String> get contentChanged => _contentChanged.stream;

  void markContentChanged(String lib) => _contentChanged.add(lib);

  bool _transfersWired = false;
  bool _keepAlive = false;
  StreamSubscription<bool>? _onlineSub;

  /// 前回の起動で残った転送を戻し、回線とサービスの見張りを始める。何度呼んでも1回だけ。
  void _wireTransfers() {
    if (_transfersWired) return;
    _transfersWired = true;
    transfers.addListener(_syncKeepAlive);
    webQueue.addListener(_syncKeepAlive);
    _onlineSub = transferPlatform.online.listen(transfers.setOnline);
    unawaited(transfers.restore());
    unawaited(webQueue.restore());
    // 目録を先に読み、一覧で「保存済み」を同期で引けるようにする
    unawaited(offline.count().then((_) => notifyListeners(),
        onError: (Object e) => debugPrint('offline manifest not loaded: $e')));
  }

  void _syncKeepAlive() {
    final want = transfers.hasActiveWork || webQueue.activeCount > 0;
    if (want == _keepAlive) return;
    _keepAlive = want;
    unawaited(transferPlatform.setKeepAlive(want));
  }

  /// 失敗した転送を積み直し、待ちを解く（接続・ロック解除・アプリへの復帰の後。KMP 版と同じ）。
  void _kickTransfers() {
    if (!_transfersWired) return;
    transfers.retryAllFailed();
    transfers.wake();
    // ネット取り込みの失敗も同じく積み直す。戻せない行（形式・URL）は retry 側が弾く
    for (final t in webQueue.tasks) {
      if (t.status == WebTaskStatus.error) webQueue.retry(t.id);
    }
  }

  /// オフライン保存を出せる環境か（暗号化して端末に置ける時だけ）。
  bool get offlineSupported => OfflineStore.supported;

  /// 選んだ写真・動画をオフライン保存に積む。積んだ件数を返す（保存済み・積み済みは数えない）。
  Future<int> saveOffline(String fallbackLib, List<MediaItem> items) async {
    if (!offlineSupported) return 0;
    _wireTransfers();
    return (await transfers.enqueueDownloads(fallbackLib, items)).length;
  }

  /// 端末にオフライン保存済みか。目録を読む前は false。
  bool isOffline(String lib, String key) => offline.hasCached(lib, key);

  /// オフライン保存した中身を復号して返す（回線なしで見る用）。無ければ null。
  Future<Uint8List?> offlineBytes(String lib, String key) =>
      offline.readBytes(lib, key);

  /// アップロードしてよい保存先か。読み取り専用や見つからないライブラリには積まない。
  /// 判定は #145 の書き込みガードと同じもの（未接続・一覧に無い・読み取り専用を止める）。
  bool canUploadTo(String? lib) => writeBlock(lib, WriteAction.upload) == null;

  /// 選んだファイルをアップロードに積む。書き込めない保存先なら積まずに 0 を返す。
  Future<int> upload(String lib, List<UploadSource> sources) async {
    if (!canUploadTo(lib)) return 0;
    _wireTransfers();
    return (await transfers.enqueueUploads(lib, sources)).length;
  }

  Future<void> init() async {
    startupError = null;
    try {
      await _initOnce().timeout(_initBudget);
    } on TimeoutException {
      startupError = '初期化がタイムアウトしました';
    } on Object catch (e) {
      startupError = describeStartupError(e);
    }
    // 前回の起動で残った転送を戻す。起動に失敗しても、台帳の行は接続後に動き出す
    _wireTransfers();
    loading = false;
    notifyListeners();
  }

  Future<void> _initOnce() async {
    final ep = await Kv.get(Keys.endpoint);
    final tk = await Kv.get(Keys.token);
    hasPin = await PinLock.hasPin();
    await _loadLockSettings();
    if (ep != null && tk != null) {
      api.setConnection(Connection(ep, tk));
      connected = true;
      locked = _gateAtStart;
      // 一覧のメタ情報を取るだけで、画面はロックが塞ぐ。PIN 入力中に取り終えておけば解除後すぐ出せる
      _loadLibraries();
    } else if (bakedEndpoint.isNotEmpty && bakedToken.isNotEmpty) {
      await _connectBaked();
    }
  }

  /// 起動失敗バナーの「再試行」。繋がっていれば一覧だけ取り直す（ロックし直さない）。
  Future<void> retryStartup() async {
    startupError = null;
    if (connected) {
      notifyListeners();
      await _loadLibraries();
      return;
    }
    loading = true;
    notifyListeners();
    await init();
  }

  void dismissStartupError() {
    startupError = null;
    notifyListeners();
  }

  /// 接続画面の「接続せずに取り込みだけ使う」。接続画面から動けない行き止まりを作らない。
  /// 端末の取り込み履歴が見えるので、ロックが効く端末ではここでも一度ロックを通す。
  void skipConnect() {
    browseOnly = true;
    _backgroundedAt = null;
    locked = canLock && _gateAtStart;
    notifyListeners();
  }

  /// 取り込みだけ使っている所から接続画面へ戻る。
  void leaveBrowseOnly() {
    browseOnly = false;
    notifyListeners();
  }

  Future<String?> connect(String endpoint, String token) async {
    final input = normalizeConnectInput(endpoint, token);
    if (input == null) {
      final ep = endpoint.trim();
      return ep.contains('://') && !ep.startsWith('https://')
          ? 'エンドポイントは https:// で始めてください'
          : connectFailedMessage;
    }
    final ok = await api
        .probe(input.endpoint, input.token)
        .timeout(_bakedProbeBudget, onTimeout: () => false);
    if (!ok) return connectFailedMessage;
    api.setConnection(Connection(input.endpoint, input.token));
    await Kv.set(Keys.endpoint, input.endpoint);
    await Kv.set(Keys.token, input.token);
    connected = true;
    browseOnly = false;
    bakedProbeFailed = false;
    startupError = null;
    notifyListeners();
    await _loadLibraries();
    return null;
  }

  Future<void> _connectBaked() async {
    final ok = await api
        .probe(bakedEndpoint, bakedToken)
        .timeout(_bakedProbeBudget, onTimeout: () => false);
    // 確かめている間にペアリングリンクや手入力で繋いだなら、そちらを優先して上書きしない
    if (connected) return;
    if (!ok) {
      // 失敗時は保存せず接続画面へ。次回起動でまた埋め込み値を試せるようにしておく
      bakedProbeFailed = true;
      return;
    }
    api.setConnection(Connection(bakedEndpoint, bakedToken));
    await Kv.set(Keys.endpoint, bakedEndpoint);
    await Kv.set(Keys.token, bakedToken);
    connected = true;
    locked = _gateAtStart;
    _loadLibraries();
  }

  bool get _gateAtStart => shouldGateAtStart(
      hasPin: hasPin, deviceLockEnabled: deviceLockEnabled, isWeb: _isWeb);

  Future<void> _loadLockSettings() async {
    deviceLockEnabled = await LockSettings.deviceLockEnabled();
    relockGraceMs = await LockSettings.relockGraceMs();
    await refreshDeviceLockAvailable();
  }

  /// 画面ロックは端末設定で後から付け外しされるので、使う度に調べ直す。
  /// 時間切れや端末側のエラーでは「無い」にせず、前に使えたならそのまま、そうでなければ unknown にする。
  Future<void> refreshDeviceLockAvailable() async {
    final prev = deviceLockProbe;
    DeviceLockProbe next;
    try {
      final ok = await deviceAuth.isAvailable().timeout(_authProbeBudget);
      next = ok ? DeviceLockProbe.available : DeviceLockProbe.unavailable;
    } on Exception catch (e) {
      debugPrint('device lock probe failed: $e');
      next = prev == DeviceLockProbe.available
          ? DeviceLockProbe.available
          : DeviceLockProbe.unknown;
    }
    if (next != prev) {
      deviceLockProbe = next;
      notifyListeners();
    }
  }

  /// r2g://setup ペアリングリンクからの接続。tools/pairing-url.mjs と KMP 版が作る
  /// `?e=<endpoint>#<token>` を読む。以前の Flutter 版の `?endpoint=..&token=..` も受ける。
  /// 読めないリンクは無視する（落とさない）。
  Future<bool> connectFromUri(Uri uri) async {
    final p = parsePairingString(uri.toString());
    String? ep = p?.endpoint;
    String? tk = p?.token;
    if (p == null) {
      ep = uri.queryParameters['endpoint'];
      tk = uri.queryParameters['token'];
    }
    if (ep == null || tk == null) return false;
    final err = await connect(ep, tk);
    return err == null;
  }

  Future<void> disconnect() async {
    await Kv.remove(Keys.endpoint);
    await Kv.remove(Keys.token);
    api.setConnection(null);
    connected = false;
    browseOnly = false;
    startupError = null;
    libraries = [];
    activeLib = null;
    notifyListeners();
  }

  Future<void> _loadLibraries() async {
    // 未接続（取り込みだけ使う時など）で取りに行くと、設定が無いという失敗をバナーに出してしまう
    if (api.conn == null) return;
    librariesLoading = true;
    notifyListeners();
    try {
      libraries = await api.libraries();
      // KMP 版と同じく最後に開いたライブラリで起動する。毎回切り替え直しになるのを防ぐ
      final saved = activeLib ?? await Kv.get(Keys.library);
      activeLib = libraries.any((l) => l.id == saved)
          ? saved
          : (libraries.isNotEmpty ? libraries.first.id : null);
      startupError = null;
    } on Object catch (e) {
      // 一覧を持っていれば失敗は出さずに手元の一覧で続ける（KMP 版 refreshLibs と同じ）。
      // 一度も取れていない時だけ、空の画面で固まって見えないよう理由を出す
      debugPrint('libraries failed: $e');
      if (libraries.isEmpty) {
        startupError = 'ライブラリを取得できませんでした（${describeStartupError(e)}）';
      }
    }
    librariesLoading = false;
    _kickTransfers();
    notifyListeners();
  }

  void setLib(String id) {
    activeLib = id;
    notifyListeners();
    Kv.set(Keys.library, id);
  }

  void unlock() {
    locked = false;
    _backgroundedAt = null;
    notifyListeners();
    // ロック中の先読みが通っていれば取り直さない。圏外で起動して空のままだった時だけ再試行する
    if (libraries.isEmpty || activeLib == null) _loadLibraries();
  }

  /// 端末の画面ロックで解除する。成功したらロックを外す。
  /// 問い合わせが固まっただけの端末でも解除できるよう、無いと確かめられた時以外は認証を出す。
  Future<bool> deviceUnlock() async {
    await refreshDeviceLockAvailable();
    if (!deviceUnlockOffered) return false;
    authenticating = true;
    try {
      final ok = await deviceAuth.verify('ロック解除');
      if (ok) unlock();
      return ok;
    } finally {
      authenticating = false;
    }
  }

  bool get canLock => canLockNow(
      hasPin: hasPin,
      deviceLockEnabled: deviceLockEnabled,
      deviceAvailable: deviceUnlockOffered);

  /// 窓を保護するか（Android の FLAG_SECURE）。ロック中だけでなく、ロックが効く間はずっと。
  /// 解除中に裏へ回った瞬間の画面が、最近使ったアプリの一覧に残るのを防ぐため。
  bool get wantsSecureWindow => locked || (sessionOpen && canLock);

  /// ロックできたら true。解除手段が無い時は覆わず false を返す（行き止まりを作らない）。
  bool lockNow() {
    _backgroundedAt = null;
    if (!canLock) return false;
    locked = true;
    notifyListeners();
    return true;
  }

  /// 設定のトグル。ONにした直後にロックして、解除できることをその場で確かめさせる（KMP版と同じ）。
  Future<void> setDeviceLockEnabled(bool on) async {
    await LockSettings.setDeviceLockEnabled(on);
    deviceLockEnabled = on;
    if (on) {
      await refreshDeviceLockAvailable();
      locked = canLock;
    } else {
      locked = false;
    }
    notifyListeners();
    if (!locked) _loadLibraries();
  }

  Future<void> setRelockGraceMs(int ms) async {
    relockGraceMs = ms;
    notifyListeners();
    await LockSettings.setRelockGraceMs(ms);
  }

  /// ファイル選択など、アプリ自身が開く外部画面の間を包む。
  /// その間に裏へ回っても「毎回ロック」で即ロックせず、externalActivityGraceMs までは待つ。
  Future<T> runExternal<T>(Future<T> Function() body) async {
    _externalActivities++;
    try {
      return await body();
    } finally {
      _externalActivities--;
    }
  }

  /// アプリがバックグラウンドへ。認証ダイアログ由来の一時停止は数えない。
  void onBackground() {
    if (authenticating || locked) return;
    // 戻った時には外部画面の結果が先に返って数が減っていることがあるので、裏へ回った時点で覚える
    _backgroundedDuringExternal = _externalActivities > 0;
    _backgroundedAt = _clock.read();
  }

  /// 画面が閉じられた（最近使ったアプリの一覧から消された等）。転送中はエンジンが残り、
  /// 次に開いた画面が同じ状態につながる。消す前は毎回起動し直しでロックが出ていたので、
  /// 猶予に関係なく、次に前面へ戻った時に起動時と同じロックをかける。
  void onDetached() {
    _screenDetached = true;
  }

  /// 前面に戻った。猶予を超えていたら再ロックする。
  /// 先にロックしてから端末の画面ロックを問い合わせる。問い合わせの遅れや失敗で
  /// ロックが抜けると、その間ずっと中身が見えてしまう。
  Future<void> onForeground() async {
    final at = _backgroundedAt;
    _backgroundedAt = null;
    final detached = _screenDetached;
    _screenDetached = false;
    if (connected) _kickTransfers();
    if (detached && sessionOpen && !locked && canLock && _gateAtStart) {
      locked = true;
      notifyListeners();
      await refreshDeviceLockAvailable();
      notifyListeners();
      return;
    }
    if (at == null || !sessionOpen) return;
    final elapsed = elapsedBetween(await at, await _clock.read());
    if (shouldRelock(
      elapsedMs: elapsed,
      graceMs: effectiveGraceMs(
          graceMs: relockGraceMs, duringExternal: _backgroundedDuringExternal),
      locked: locked,
      canLock: canLock,
    )) {
      locked = true;
      notifyListeners();
    }
    await refreshDeviceLockAvailable();
    notifyListeners();
  }

  Future<void> refreshPinState() async {
    hasPin = await PinLock.hasPin();
    notifyListeners();
  }

  /// 端末のギャラリーへの書き出し口。ビューワー・一覧の長押しのどちらからも使う。
  late DeviceExporter deviceExporter = DeviceExporter(api: api);

  bool get deviceExportSupported => deviceExporter.supported;

  /// 「端末に保存」。古い Android では保存許可のダイアログが出て裏へ回るので、登録の所だけ外部画面として包む。
  /// 失敗は DeviceExportError / ApiError で返し、呼び出し側が文言を出す。
  Future<void> exportToDevice(MediaItem item, {String? lib}) {
    final l = item.lib ?? lib ?? activeLib;
    if (l == null) {
      return Future.error(const DeviceExportError('ライブラリが未選択です'));
    }
    return deviceExporter.export(item, l, guardSave: runExternal);
  }

  @override
  void dispose() {
    _onlineSub?.cancel();
    _contentChanged.close();
    super.dispose();
  }
}

/// 接続に失敗した時の文言（KMP 版の接続画面と同じ）。
const connectFailedMessage = '接続できませんでした。URLとトークンを確認してください。';

/// 起動失敗の理由を画面に出せる形にする。長すぎる文やトークンらしき並びは出さない。
String describeStartupError(Object e) {
  var msg = e.toString();
  msg = msg.replaceAll(RegExp(r'Bearer\s+\S+'), 'Bearer ***');
  if (msg.trim().isEmpty) msg = '不明なエラー';
  return msg.length > 240 ? msg.substring(0, 240) : msg;
}

/// 選択対象の安定キー（ライブラリ横断選択に備えて lib+key で識別）。
class SelKey {
  final String lib;
  final String key;
  const SelKey(this.lib, this.key);
  @override
  bool operator ==(Object o) => o is SelKey && o.lib == lib && o.key == key;
  @override
  int get hashCode => Object.hash(lib, key);
}

/// 一覧画面の状態。ページング・選択・一括操作・バックフィルをまとめる。
class GalleryState extends ChangeNotifier {
  final ApiClient api;

  /// フォルダを辿る画面は直下だけを取り、サブフォルダを [folders] に並べる。
  final String prefix;
  final bool recursive;
  GalleryState(this.api,
      {this.prefix = '',
      this.recursive = true,
      this.loadMoreBackoff = const Duration(seconds: 3)});

  /// 続きページの取得に失敗した後、次を試すまで空ける時間。
  /// スクロール通知ごとに呼ばれるので、空けないと圏外のあいだ再試行と再描画を繰り返す。
  final Duration loadMoreBackoff;
  // 壁時計だと端末時刻が過去へ戻った時に差が負になり、追いつくまで続きが読めなくなる
  Stopwatch? _sinceLoadMoreFailure;

  List<MediaItem> items = [];
  List<String> folders = [];
  String? cursor;
  bool loading = false;
  bool loadingMore = false;
  String? error;
  int epoch = 0;

  bool selectionMode = false;
  final Set<SelKey> selection = {};
  bool bulkBusy = false;
  String? bulkError;

  // 一覧アイテムのサムネバックフィルは1試行ずつに留める（失敗ループ防止）
  final Set<String> thumbTried = {};

  /// バックフィルでサムネを作れなかった・送れなかった件数。各行は1回しか試さんので、
  /// 握りつぶすと worker 側の拒否（415 など）が続いても誰にも見えなくなる
  int thumbBackfillFailures = 0;

  Future<void> refresh(String lib) async {
    final e = ++epoch;
    loading = true;
    // 取り直しの間に戻ってきた古い続きページを積まんよう、ページ送りも打ち切る
    loadingMore = false;
    _sinceLoadMoreFailure = null;
    error = null;
    notifyListeners();
    try {
      // KMP 版のホームと同じく、サブフォルダの中まで含めた全メディアを出す
      final page =
          await api.folder(lib, prefix: prefix, cursor: null, recursive: recursive);
      if (e != epoch) return;
      items = page.items;
      folders = page.folders;
      cursor = page.cursor;
    } catch (err) {
      if (e != epoch) return;
      error = err.toString();
    }
    loading = false;
    notifyListeners();
  }

  Future<void> loadMore(String lib) async {
    if (cursor == null || loadingMore || loading) return;
    final sinceFailure = _sinceLoadMoreFailure;
    if (sinceFailure != null && sinceFailure.elapsed < loadMoreBackoff) return;
    final e = epoch;
    loadingMore = true;
    notifyListeners();
    try {
      final page = await api.folder(lib,
          prefix: prefix, cursor: cursor, recursive: recursive);
      if (e != epoch) return;
      final seen = {for (final it in items) '${it.lib}:${it.key}'};
      items = [
        ...items,
        ...page.items.where((it) => seen.add('${it.lib}:${it.key}')),
      ];
      if (!recursive) folders = page.folders;
      cursor = page.cursor;
      _sinceLoadMoreFailure = null;
    } catch (err) {
      if (e != epoch) return;
      _sinceLoadMoreFailure = Stopwatch()..start();
      // 続きの取得失敗も黙らせず、一覧の上の帯で知らせる
      error = err.toString();
    }
    loadingMore = false;
    notifyListeners();
  }

  SelKey selKeyOf(MediaItem it, String fallbackLib) =>
      SelKey(it.lib ?? fallbackLib, it.key);

  void toggleSelect(MediaItem it, String fallbackLib) {
    final k = selKeyOf(it, fallbackLib);
    if (selection.contains(k)) {
      selection.remove(k);
    } else {
      selection.add(k);
      selectionMode = true;
    }
    if (selection.isEmpty) selectionMode = false;
    notifyListeners();
  }

  void startSelection(MediaItem it, String fallbackLib) {
    selection.add(selKeyOf(it, fallbackLib));
    selectionMode = true;
    notifyListeners();
  }

  void clearSelection() {
    selection.clear();
    selectionMode = false;
    notifyListeners();
  }

  /// 見えている全件が選択済みか。選択は取り直し後も残るので件数だけでは比べない。
  bool allSelected(String fallbackLib) =>
      items.isNotEmpty &&
      items.every((it) => selection.contains(selKeyOf(it, fallbackLib)));

  /// 全部選択済みなら外し、そうでなければ全部選ぶ。画面外に残った選択は触らない。
  void toggleAll(String fallbackLib) {
    if (allSelected(fallbackLib)) {
      selection.removeAll(items.map((it) => selKeyOf(it, fallbackLib)));
    } else {
      selection.addAll(items.map((it) => selKeyOf(it, fallbackLib)));
    }
    selectionMode = selection.isNotEmpty;
    notifyListeners();
  }

  /// 日付見出しの丸。その日が全部選ばれていれば外し、そうでなければまとめて選ぶ。
  void toggleDay(List<MediaItem> day, String fallbackLib) {
    final keys = day.map((it) => selKeyOf(it, fallbackLib)).toList();
    if (keys.every(selection.contains)) {
      selection.removeAll(keys);
    } else {
      selection.addAll(keys);
    }
    selectionMode = selection.isNotEmpty;
    notifyListeners();
  }

  void selectAll(List<MediaItem> visible, String fallbackLib) {
    for (final it in visible) {
      selection.add(selKeyOf(it, fallbackLib));
    }
    selectionMode = selection.isNotEmpty;
    notifyListeners();
  }

  /// 選択分をゴミ箱へ。成功数/失敗数と、元に戻すための控えを返す。失敗時にエラーを保持する。
  Future<TrashOutcome> bulkTrash(
    String lib,
    Future<void> Function() refresh,
  ) async {
    if (bulkBusy) return const TrashOutcome([], 0, 0);
    bulkBusy = true;
    bulkError = null;
    notifyListeners();
    final targets = selection.toList();
    selection.clear();
    selectionMode = false;
    final res =
        await trashAll(api, [for (final t in targets) (lib: t.lib, key: t.key)]);
    bulkBusy = false;
    if (res.failed > 0) bulkError = '${res.failed}件をゴミ箱に移せませんでした';
    notifyListeners();
    await refresh();
    return res;
  }

  /// サムネ未生成の画像を1枚ずつ原本取得→縮小→PUTでバックフィル。
  /// 一斉に投げると原本の取得が表示用サムネの取得と回線を奪い合い、切替直後の一覧が詰まる。
  /// KMP 版と同じく1本ずつ順番に流す。
  void backfillThumbs(
    String lib, {
    required Future<Uint8List?> Function(MediaItem) makeThumb,
    Future<void> Function(MediaItem)? onThumbStored,
  }) {
    final targets = [
      for (final item in items)
        if (!item.thumbStored &&
            (item.isImage || item.isVideo) &&
            thumbTried.add('${item.lib ?? lib}:${item.key}'))
          item,
    ];
    if (targets.isEmpty) return;
    _backfillQueue.addAll(targets.map((t) => (lib: lib, item: t)));
    if (_backfilling) return;
    _backfilling = true;
    () async {
      // 画像は一覧の時点で原本由来の thumbUrl を持つので再取得は要らない。
      // 動画だけ thumbUrl が null のままなので、作れた時だけその行の署名URLを引き直す
      String? videoLib;
      final storedVideos = <String>{};
      while (_backfillQueue.isNotEmpty && !_disposed) {
        final next = _backfillQueue.removeAt(0);
        try {
          final thumb = await makeThumb(next.item);
          if (thumb != null && thumb.isNotEmpty) {
            await api.putThumb(next.item.lib ?? next.lib, next.item.key, thumb);
            if (next.item.isVideo) {
              videoLib = next.lib;
              storedVideos.add(_idOf(next.item, next.lib));
            }
            await onThumbStored?.call(next.item);
          }
        } catch (e) {
          thumbBackfillFailures++;
          debugPrint('thumb backfill failed ($thumbBackfillFailures): '
              '${next.item.key}: $e');
        }
      }
      // 引き直しは待たずに投げる。待つ間に来た呼び出しがキューに積まれたまま取り残されるため
      _backfilling = false;
      final lib = videoLib;
      if (lib != null && !_disposed) unawaited(_adoptStoredThumbs(lib, storedVideos));
    }();
  }

  String _idOf(MediaItem it, String fallbackLib) =>
      '${it.lib ?? fallbackLib}:${it.key}';

  /// サムネを保存できた動画の行だけを、サーバーの最新の行に差し替える。
  /// refresh() は先頭 1 ページに巻き戻して続きページを捨て、スクロール位置が飛ぶので使わない。
  /// 一覧は新着順で並ぶため、対象が見つかるまで先頭から読み込み済みの件数分だけ辿る。
  Future<void> _adoptStoredThumbs(String lib, Set<String> ids) async {
    final e = epoch;
    final pending = {...ids};
    final loaded = items.length;
    var walked = 0;
    String? cur;
    try {
      while (pending.isNotEmpty && !_disposed) {
        final page = await api.folder(lib, cursor: cur, recursive: true);
        if (e != epoch) return;
        final fresh = {for (final it in page.items) _idOf(it, lib): it};
        items = [
          for (final it in items)
            if (fresh.containsKey(_idOf(it, lib)) &&
                pending.remove(_idOf(it, lib)))
              fresh[_idOf(it, lib)]!
            else
              it,
        ];
        walked += page.items.length;
        cur = page.cursor;
        if (cur == null || walked >= loaded) break;
      }
    } catch (_) {
      // 引けなかった行はサムネ無しのまま。次に一覧を取り直した時に揃う
    }
    notifyListeners();
  }

  final List<({String lib, MediaItem item})> _backfillQueue = [];
  bool _backfilling = false;
  bool _disposed = false;

  @override
  void notifyListeners() {
    // 画面を閉じた後に通信が返っても落ちんようにする（ロック画面へ切り替わった時など）
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
