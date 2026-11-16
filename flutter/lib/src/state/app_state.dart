import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../config/baked.dart' as baked;
import '../grid/photos_chrome.dart';
import '../grid/media_kind.dart';
import '../grid/sort_mode.dart';
import '../offline/offline_store.dart';
import '../store/device_auth.dart';
import '../store/kv.dart';
import '../store/listing_cache.dart';
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
    ListingCache? listingCache,
  })  : api = api ?? ApiClient(),
        offline = offline ??
            OfflineStore(endpoint: () => api?.conn?.endpoint),
        listingCache = listingCache ?? ListingCache.platform(),
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
    connOf: () => api.conn,
  );

  /// 転送を裏でも続けるサービスと回線の知らせ。
  final TransferPlatform transferPlatform;

  /// 端末に暗号化して置くオフライン保存。
  final OfflineStore offline;

  /// 一覧の先頭ページの控え。起動直後に回線を待たず最初の写真を出すため。
  final ListingCache listingCache;

  /// アップロードとオフライン保存のキュー。画面ではなくここが持ち、ロック中も裏で続ける。
  late final TransferQueue transfers = TransferQueue(
    api: ApiClientTransferApi(api),
    offline: offline,
    makeThumb: thumbFromFile,
    configured: () => api.conn != null,
    connOf: () => api.conn,
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
    webQueue.wake();
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
  /// [albumId] はアップロード時に選んだ入れ先（#102）。
  Future<int> upload(String lib, List<UploadSource> sources,
      {String? albumId}) async {
    if (!canUploadTo(lib)) return 0;
    _wireTransfers();
    return (await transfers.enqueueUploads(lib, sources, albumId: albumId))
        .length;
  }

  /// 起動時の復元。ペアリングリンクの処理など、保存した接続が戻ってからでないと
  /// 判定を誤る処理はこれを待つ。init を呼んでいなければ null
  Future<void>? get ready => _inited;
  Future<void>? _inited;

  Future<void> init() => _inited ??= _init();

  Future<void> _init() async {
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
      _lastEndpoint = ep;
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
    // 再試行なので前の復元を待っていても意味がない。もう一度取り直す
    _inited = null;
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

  /// 接続先を差し替えた回数。同じライブラリ id の別の接続先でも画面の一覧・選択を作り直す合図に使う
  int connectionGen = 0;

  /// 最後に実際に繋がっていた送り先。切断で接続が null になった後も残し、
  /// 別の接続先へ繋ぎ直した時に残った転送を新しい送り先へ誤送せんよう比べる
  String? _lastEndpoint;

  /// 送り先が変わる時に呼ぶ。前の送り先へ向けて積んだ転送・取り込みを止め、旧接続先の一覧を捨てる。
  /// 比べる相手は今の接続、無ければ最後に繋がっていた送り先（切断→別の接続先でも漏れないため）。
  /// 行は取り消さず一時停止に留める。退避したファイルも残り、同じ送り先へ戻れば続きから送れる
  void _pauseUnsentIfSwitching(String endpoint) {
    final staleTo = api.conn?.endpoint ?? _lastEndpoint;
    if (staleTo == null || isSameEndpoint(staleTo, endpoint)) return;
    transfers.pauseUnsent();
    webQueue.pauseUnsent();
    // 旧接続先の一覧・選択を新しい接続先のものとして見せない。取得に失敗しても残らない
    libraries = [];
    activeLib = null;
  }

  // connect / tryConnect / saveConnection で入力の確かめ方と文言を揃える
  ({String endpoint, String token})? _validInput(
      String endpoint, String token, void Function(String) onError) {
    final input = normalizeConnectInput(endpoint, token);
    if (input != null) return input;
    final ep = endpoint.trim();
    onError(ep.contains('://') && !ep.startsWith('https://')
        ? 'エンドポイントは https:// で始めてください'
        : connectFailedMessage);
    return null;
  }

  Future<void> _applyConnection(String endpoint, String token) async {
    _pauseUnsentIfSwitching(endpoint);
    api.setConnection(Connection(endpoint, token));
    _lastEndpoint = endpoint;
    await Kv.set(Keys.endpoint, endpoint);
    await Kv.set(Keys.token, token);
    connected = true;
    browseOnly = false;
    bakedProbeFailed = false;
    startupError = null;
    // 同じライブラリ id でも中身は別の接続先のもの。先に上げて、通知で画面が古い一覧を使い続けないようにする
    connectionGen++;
    notifyListeners();
    await _loadLibraries();
  }

  // 確かめてから差し替えるまでの間に別の接続が割り込まんよう、接続の確かめと適用は1本に並べる
  Future<void>? _connectLock;

  Future<T> _connectSerial<T>(Future<T> Function() body) async {
    final prev = _connectLock;
    final done = Completer<void>();
    _connectLock = done.future;
    try {
      if (prev != null) await prev;
      return await body();
    } finally {
      done.complete();
    }
  }

  Future<String?> connect(String endpoint, String token) =>
      _connectSerial(() => _connectNow(endpoint, token));

  Future<String?> _connectNow(String endpoint, String token) async {
    String? err;
    final input = _validInput(endpoint, token, (e) => err = e);
    if (input == null) return err;
    // 転送は送るたびに今の接続を読むので、送り先が変わると待機中の物が新しい送り先へ漏れる。
    // saveConnection と同じく未送信が残る切り替えは断る（ペアリングリンクもここを通る）
    final cur = api.conn;
    if (cur != null &&
        !isSameEndpoint(cur.endpoint, input.endpoint) &&
        hasUnsentTransfers) {
      return unsentTransfersMessage;
    }
    final ok = await api
        .probe(input.endpoint, input.token)
        .timeout(_bakedProbeBudget, onTimeout: () => false);
    if (!ok) return connectFailedMessage;
    await _applyConnection(input.endpoint, input.token);
    return null;
  }

  /// 接続先の変更画面の保存。connect と違い、届かない／トークンが違うを区別した理由を返す。
  /// 確かめて成功した時だけ接続を差し替え、失敗では今の接続にも保存値にも触れない。
  Future<String?> saveConnection(String endpoint, String token) =>
      _connectSerial(() => _saveConnectionNow(endpoint, token));

  Future<String?> _saveConnectionNow(String endpoint, String token) async {
    String? err;
    final input = _validInput(endpoint, token, (e) => err = e);
    if (input == null) return err;
    // 転送は送るたびに今の接続を読むので、切り替えると A に向けて積んだものが B へ送られる。
    // 同じ送り先（トークンの差し替えだけ）なら変わらないので止めない。パスが違えば同じホストでも別物
    final cur = api.conn;
    if (cur != null &&
        !isSameEndpoint(cur.endpoint, input.endpoint) &&
        hasUnsentTransfers) {
      return unsentTransfersMessage;
    }
    final r = await api
        .probeOutcome(input.endpoint, input.token)
        .timeout(_bakedProbeBudget, onTimeout: () => ProbeOutcome.unreachable);
    if (!r.success) return _probeReason(r);
    await _applyConnection(input.endpoint, input.token);
    return null;
  }

  static const unsentTransfersMessage =
      '送り終えていない転送があります。終わるのを待つか、転送の一覧から消してから切り替えてください。';

  /// まだ送る可能性のある転送の行があるか。失敗の行も接続のたびに自動で再試行されるので数える。
  /// ネット取り込みも同じ接続へ上げるので含める。
  bool get hasUnsentTransfers =>
      transfers.tasks.any((t) =>
          t.status != TransferStatus.done &&
          t.status != TransferStatus.cancelled) ||
      webQueue.tasks.any((t) =>
          t.status != WebTaskStatus.done &&
          t.status != WebTaskStatus.cancelled);

  String _probeReason(ProbeOutcome r) => r.tokenRejected
      ? 'トークンが違います。確認してください。'
      : '接続先に届きません。URLとネットワークを確認してください。';

  /// 接続先を保存せずに試す。今の接続・保存済みの値には一切触れない。
  /// 返す文字列は失敗の理由、成功なら null（件数は取れた時だけ）。
  Future<({String? error, int? libraryCount})> tryConnect(
      String endpoint, String token) async {
    String? err;
    final input = _validInput(endpoint, token, (e) => err = e);
    if (input == null) return (error: err, libraryCount: null);
    final r = await api
        .probeOutcome(input.endpoint, input.token)
        .timeout(_bakedProbeBudget, onTimeout: () => ProbeOutcome.unreachable);
    if (r.success) return (error: null, libraryCount: r.libraryCount);
    return (error: _probeReason(r), libraryCount: null);
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
    _pauseUnsentIfSwitching(bakedEndpoint);
    api.setConnection(Connection(bakedEndpoint, bakedToken));
    _lastEndpoint = bakedEndpoint;
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

  /// r2g://setup のリンクが運ぶ接続先とトークンを読む。tools/pairing-url.mjs と KMP 版が作る
  /// `?e=<endpoint>#<token>` 形式と、以前の Flutter 版の `?endpoint=..&token=..` の両方を受ける。
  /// 読めないリンクは null（呼ぶ側は無視してよい）。
  ({String endpoint, String token})? pairingParams(Uri uri) {
    final p = parsePairingString(uri.toString());
    if (p != null) return (endpoint: p.endpoint, token: p.token);
    final ep = uri.queryParameters['endpoint'];
    final tk = uri.queryParameters['token'];
    if (ep == null || tk == null) return null;
    return (endpoint: ep, token: tk);
  }

  /// リンクが、今の接続とは別の送り先を指すか。切り替える前に確認を取るかどうかの判定で、
  /// 未接続（初回ペアリング）・同じ送り先・読めないリンクは false（確認なしでよい）。
  /// トークンの差し替えだけなら同じ送り先なので、パスまで見て比べる
  bool pairingNeedsConfirm(Uri uri) {
    final p = pairingParams(uri);
    final cur = api.conn;
    if (p == null || cur == null) return false;
    return !isSameEndpoint(cur.endpoint, p.endpoint);
  }

  /// r2g://setup ペアリングリンクからの接続。
  /// 読めないリンクは無視する（落とさない）。別の送り先への切り替えに見えるリンクを
  /// ここへ直接渡すと確認なしで切り替わるので、UI 側は先に [pairingNeedsConfirm] で確かめる
  Future<bool> connectFromUri(Uri uri) async {
    final p = pairingParams(uri);
    if (p == null) return false;
    final err = await connect(p.endpoint, p.token);
    return err == null;
  }

  Future<void> disconnect() async {
    await Kv.remove(Keys.endpoint);
    await Kv.remove(Keys.token);
    // 接続を外した後も前の接続先の一覧が端末に残り続けないよう、控えも捨てる。
    // 後片付けを待たずに画面だけは即座に未接続へ戻す。控えは端末ごとに別の置き場なので、
    // 消し残しがあっても次の接続では ListingScope の違いで参照されない
    unawaited(listingCache.clear());
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
  bool operator ==(Object other) =>
      other is SelKey && other.lib == lib && other.key == key;
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
      this.sort = SortMode.dateNew,
      this.kind = MediaKind.all,
      this.loadMoreBackoff = const Duration(seconds: 3),
      this.cache});

  SortMode sort;

  /// 写真/動画の絞り込み（#26）。Worker の type パラメータで全件に効かせる
  MediaKind kind;

  /// 先頭ページの控えの置き場。null なら控えない（テストの既定）。
  final ListingCache? cache;

  /// 端末に残しておいた先頭ページを出していて、まだ回線の答えで置き換わっていない間は true。
  /// この間の行は署名URLの期限が切れていることがある。
  bool showingCached = false;

  /// 一覧全体のメディア件数。Worker が返した時だけ入る。
  int? total;

  /// 控えに残す件数。Worker の1ページ分あれば最初の画面は埋まる
  static const snapshotSize = 200;

  Future<void>? _revalidation;
  Future<void> _saving = Future.value();
  int _softSeq = 0;

  /// 先に一覧から外し、ゴミ箱へ送っている最中の行。送り終わるまでは Worker の一覧に
  /// まだ載っているので、その間に届いたページから蘇らせない。
  final Set<String> _trashing = {};

  List<MediaItem> _withoutTrashing(List<MediaItem> page) => _trashing.isEmpty
      ? page
      : [
          for (final it in page)
            if (!_trashing.contains(_rowId(it))) it,
        ];

  /// 並び順を変えたのに先頭ページをまだ取れていない間は true。この間に古い順の
  /// cursor を新しい順へ送ると、既出の分を返す・途中で終わる、になるため。
  bool _needsFirstPage = false;

  /// 今の [items] を Worker が [sort] の順で返したか。古い Worker は sort を無視して
  /// 新着順で返すので、その時だけ端末側で並べ直す。
  bool _serverSorted = false;

  /// Worker が並べた物は触らない(触ると続きの読み込みで位置が跳ぶ)。
  List<MediaItem> ordered() => _serverSorted ? items : sort.sorted(items);

  Future<void> changeSort(SortMode m, String lib) {
    if (m == sort) return Future.value();
    sort = m;
    // 取り直しが失敗しても、古い並びの cursor を新しい並びで使わせない
    cursor = null;
    _serverSorted = false;
    _needsFirstPage = true;
    return refresh(lib);
  }

  /// 種別の絞り込みを変える。cursor は絞り込み前の一覧の物なので使い回せない
  Future<void> changeKind(MediaKind k, String lib) {
    if (k == kind) return Future.value();
    kind = k;
    cursor = null;
    _serverSorted = false;
    _needsFirstPage = true;
    return refresh(lib);
  }

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

  /// 「すべて選択」で残りページを取り切っている最中。バーに読み込み中を出し、
  /// スクロール由来の続き読み込みがページを二重に進めないよう止める
  bool selectAllBusy = false;

  // 一覧アイテムのサムネバックフィルは1試行ずつに留める（失敗ループ防止）
  final Set<String> thumbTried = {};

  /// バックフィルでサムネを作れなかった・送れなかった件数。各行は1回しか試さんので、
  /// 握りつぶすと worker 側の拒否（415 など）が続いても誰にも見えなくなる
  int thumbBackfillFailures = 0;

  /// 先頭から取り直して一覧を置き換える。[fresh] は利用者が引っ張って取り直した時だけ立て、
  /// Worker に索引ではなくバケットを数え直させる（重いので自動の取り直しには使わない）。
  Future<void> refresh(String lib, {bool fresh = false}) {
    final run = _refresh(lib, fresh);
    _revalidation = run;
    return run;
  }

  Future<void> _refresh(String lib, bool fresh) async {
    final e = ++epoch;
    loading = true;
    // 取り直しの間に戻ってきた古い続きページを積まんよう、ページ送りも打ち切る
    loadingMore = false;
    _sinceLoadMoreFailure = null;
    error = null;
    // 手元に何も無い時だけ控えを出す。回線を待たずにディスクのサムネで最初の画面を埋めるため
    if (items.isEmpty) unawaited(_showCached(lib, e));
    notifyListeners();
    try {
      // KMP 版のホームと同じく、サブフォルダの中まで含めた全メディアを出す
      final page = await api.folder(lib,
          prefix: prefix,
          cursor: null,
          recursive: recursive,
          sort: sort.apiValue,
          type: kind.apiValue,
          fresh: fresh);
      if (e != epoch) return;
      _adoptFirstPage(page);
      _saveSnapshot(lib);
      // 古い Worker が type を無視する時、先頭ページが全部除かれても 0 件で止めず
      // 続きを読み進める。空のままだと「メディアが無い」に見えるし、行が無いので
      // スクロール由来の続き読み込みも起きない
      while (e == epoch && !_disposed && items.isEmpty && cursor != null) {
        final before = cursor;
        await _fetchNextPage(lib);
        if (cursor == before) break;
      }
    } catch (err) {
      if (e != epoch) return;
      // 控えを出していれば消さずに残し、失敗は上の帯で知らせる
      error = err.toString();
    }
    loading = false;
    notifyListeners();
  }

  void _adoptFirstPage(FolderPage page) {
    _serverSorted = page.sort == sort.apiValue;
    _needsFirstPage = false;
    showingCached = false;
    // 古い Worker は type を無視するので、混ざった行は端末側で除く
    items = _withoutTrashing(page.items).where(kind.matches).toList();
    folders = page.folders;
    cursor = page.cursor;
    total = page.total;
  }

  ListingScope? _scopeFor(String lib) {
    final endpoint = api.conn?.endpoint;
    if (endpoint == null) return null;
    return ListingScope(
        endpoint: endpoint,
        lib: lib,
        prefix: prefix,
        recursive: recursive,
        sort: sort.apiValue,
        type: kind.apiValue ?? 'all');
  }

  Future<void> _showCached(String lib, int e) async {
    final c = cache, scope = _scopeFor(lib);
    if (c == null || scope == null) return;
    final hit = await c.read(scope);
    // 回線の答えが先に来た・別の取り直しが始まった・その間に行が載った時は使わない
    if (hit == null || _disposed || e != epoch || !loading || items.isNotEmpty) {
      return;
    }
    items = hit.items;
    folders = hit.folders;
    total = hit.total;
    _serverSorted = hit.serverSort == sort.apiValue;
    // 控えの cursor は古くて当てにならない。続きは回線の先頭ページが取れてから頼む
    cursor = null;
    _needsFirstPage = true;
    showingCached = true;
    notifyListeners();
  }

  /// 今の先頭を控えに書く。ゴミ箱へ送った行が次の起動で控えから蘇らんよう、行を変えた後にも呼ぶ。
  /// 書き込みは順に流し、古い中身が後から上書きせんようにする
  void _saveSnapshot(String lib) {
    final c = cache, scope = _scopeFor(lib);
    if (c == null || scope == null) return;
    final snap = CachedListing(
      items: items.take(snapshotSize).toList(),
      folders: folders,
      serverSort: _serverSorted ? sort.apiValue : null,
      total: total,
      savedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _saving = _saving.then((_) => c.write(scope, snap));
  }

  /// 一覧を開いたまま中身が変わった時（アップロード・取り込みの完了、別のタブでの復元など）の取り直し。
  /// 先頭ページだけ取り、読み込み済みの続きのページと cursor は残して差分だけ反映する。
  /// [refresh] だと先頭ページに巻き戻り、読み進めた位置と続きのページを失うため。
  Future<void> softRefresh(String lib) async {
    if (loading || items.isEmpty || _needsFirstPage || showingCached) {
      return refresh(lib);
    }
    final e = epoch;
    final seq = ++_softSeq;
    try {
      final page = await api.folder(lib,
          prefix: prefix,
          cursor: null,
          recursive: recursive,
          sort: sort.apiValue,
          type: kind.apiValue);
      if (e != epoch || seq != _softSeq) return;
      _mergeFirstPage(page);
      error = null;
      _saveSnapshot(lib);
    } catch (err) {
      if (e != epoch || seq != _softSeq) return;
      error = err.toString();
    }
    notifyListeners();
  }

  String _rowId(MediaItem it) => '${it.lib}:${it.key}';

  /// 取り直した先頭ページを読み込み済みの一覧へ重ねる。先頭ページの範囲（読み込み済みの中で
  /// 先頭ページと重なる最後の行まで）は先頭ページの中身に置き換え、その後ろは残す。
  void _mergeFirstPage(FolderPage page) {
    final fetched = {for (final it in page.items) _rowId(it)};
    var last = -1;
    for (var i = 0; i < items.length; i++) {
      if (fetched.contains(_rowId(items[i]))) last = i;
    }
    // 重なりが無い・並びの扱いが変わった・先頭ページで全件の時は、続きを残す意味が無い
    if (last < 0 ||
        page.cursor == null ||
        (page.sort == sort.apiValue) != _serverSorted) {
      _adoptFirstPage(page);
      return;
    }
    final coveredAll = last >= items.length - 1;
    items = [
      ..._withoutTrashing(page.items).where(kind.matches),
      ...items.skip(last + 1).where((it) => !fetched.contains(_rowId(it))),
    ];
    // 読み込み済みが全部先頭ページの範囲に収まっていたなら、続きは先頭ページの cursor から
    if (coveredAll) cursor = page.cursor;
    folders = page.folders;
    total = page.total;
  }

  /// 一覧のタップで開く行を決める。控えを出している間は署名URLが切れていることがあり、
  /// そのまま開くと原本を読めない。取り直しを待ち、同じキーの新しい行で開く。消えていたら null。
  Future<({List<MediaItem> items, int index})?> openTarget(
      List<MediaItem> shown, int index) async {
    final it = shown[index];
    if (!showingCached || !signedUrlExpired(it.url)) {
      return (items: shown, index: index);
    }
    while (showingCached && loading) {
      final r = _revalidation;
      if (r == null) break;
      await r;
    }
    if (_disposed) return null;
    final now = ordered();
    final at = now.indexWhere((x) => x.key == it.key && x.lib == it.lib);
    return at < 0 ? null : (items: now, index: at);
  }

  Future<void> loadMore(String lib) async {
    if (loadingMore || loading || selectAllBusy) return;
    if (_needsFirstPage) {
      await refresh(lib);
      return;
    }
    if (cursor == null) return;
    final sinceFailure = _sinceLoadMoreFailure;
    if (sinceFailure != null && sinceFailure.elapsed < loadMoreBackoff) return;
    await _fetchNextPage(lib);
  }

  /// 続きの 1 ページを実際に取る。入口のガード（backoff・取り合い）は呼び出し側の責務。
  Future<void> _fetchNextPage(String lib) async {
    final e = epoch;
    loadingMore = true;
    notifyListeners();
    try {
      final page = await api.folder(lib,
          prefix: prefix,
          cursor: cursor,
          recursive: recursive,
          sort: sort.apiValue,
          type: kind.apiValue);
      if (e != epoch) return;
      // 先頭ページは Worker の並びだったのに、続きが別の並びで返ったら cursor は使えない
      // (Worker の入れ替わり)。続きを継ぎ足さず先頭から取り直す
      if (_serverSorted && page.sort != sort.apiValue) {
        loadingMore = false;
        await refresh(lib);
        return;
      }
      final seen = {for (final it in items) '${it.lib}:${it.key}'};
      items = [
        ...items,
        ..._withoutTrashing(page.items)
            .where(kind.matches)
            .where((it) => seen.add('${it.lib}:${it.key}')),
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

  /// 「すべて選択」。続きページが残っていたら先に全部取り切ってから選ぶ。
  /// 読み込み済み分だけ選ぶと「選んだはずの写真が保存されない」に見えるため。
  /// 途中で取れなかった時は、取れた分だけ選ぶ（失敗は一覧の帯で知らせ済み）。
  Future<void> selectAllFully(String fallbackLib) async {
    if (selectAllBusy) return;
    selectAllBusy = true;
    notifyListeners();
    try {
      // スクロール由来の続き読み込みが飛んでいたら、終わるまで待ってから回り始める
      while (loadingMore || loading) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (_disposed) return;
      }
      while (cursor != null) {
        final before = cursor;
        await _fetchNextPage(fallbackLib);
        if (_disposed) return;
        // cursor が進まない＝取得失敗（帯で知らせ済み）か、同じ続きを返すおかしな応答
        if (cursor == before) break;
      }
      selection.addAll(items.map((it) => selKeyOf(it, fallbackLib)));
      selectionMode = selection.isNotEmpty;
    } finally {
      selectAllBusy = false;
      notifyListeners();
    }
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

  /// 操作が失敗した時に、先に解いた選択を戻す。
  void reselect(Iterable<SelKey> keys) {
    selection.addAll(keys);
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

  /// [test] に当たる行を一覧から外す。元の位置へ戻せるよう、位置と直前の行を控えて返す。
  List<RemovedRow> removeRows(bool Function(MediaItem it) test) {
    final out = <RemovedRow>[];
    final kept = <MediaItem>[];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (test(it)) {
        out.add(RemovedRow(it, i, i == 0 ? null : _rowId(items[i - 1])));
      } else {
        kept.add(it);
      }
    }
    if (out.isNotEmpty) {
      items = kept;
      notifyListeners();
    }
    return out;
  }

  /// [removeRows] で外した行を元の位置へ戻す。外した後に一覧が変わっていても、直前の行の後ろへ置く。
  /// 取り直しで既に戻っている行は重ねない。
  void reinsertRows(List<RemovedRow> rows) {
    if (rows.isEmpty) return;
    final list = [...items];
    final present = {for (final it in list) _rowId(it)};
    for (final r in [...rows]..sort((a, b) => a.index.compareTo(b.index))) {
      if (!present.add(_rowId(r.item))) continue;
      final prev = r.prevId;
      var at = 0;
      if (prev != null) {
        final p = list.indexWhere((it) => _rowId(it) == prev);
        at = p >= 0 ? p + 1 : r.index.clamp(0, list.length);
      }
      list.insert(at, r.item);
    }
    items = list;
    notifyListeners();
  }

  /// [targets] をすぐ一覧から外し、ゴミ箱へは裏で送る（待たせると操作がもたつくため）。
  /// 送れなかった行は元の位置へ戻す。一覧の取り直しはしない。
  PendingTrash trashOptimistic(String lib, List<SelKey> targets) {
    final set = targets.toSet();
    selection.removeAll(set);
    if (selection.isEmpty) selectionMode = false;
    bulkError = null;
    final rows = removeRows((it) => set.contains(selKeyOf(it, lib)));
    final sending = {for (final r in rows) _rowId(r.item)};
    _trashing.addAll(sending);
    notifyListeners();
    _saveSnapshot(lib);
    final done = trashAll(api, [for (final t in targets) (lib: t.lib, key: t.key)])
        .then((res) {
      _trashing.removeAll(sending);
      if (res.failed > 0) {
        final failed = {for (final f in res.failedTargets) SelKey(f.lib, f.key)};
        bulkError = '${res.failed}件をゴミ箱に移せませんでした';
        reinsertRows([
          for (final r in rows)
            if (failed.contains(selKeyOf(r.item, lib))) r,
        ]);
        _saveSnapshot(lib);
      }
      return res;
    });
    return PendingTrash(targets.length, rows, done);
  }

  /// 「元に戻す」。外した行はすぐ元の位置へ戻し、ゴミ箱へ送り終わるのを待ってから戻す。
  /// 戻せなかった行は外し直す（404 は別の所で先に戻されたので残す）。
  Future<RestoreOutcome> undoTrash(String lib, PendingTrash p) async {
    reinsertRows(p.rows);
    final res = await p.done;
    final out = await restoreAll(api, res.receipts);
    final gone = <SelKey>{
      for (final r in res.receipts)
        if (out.failures[r.trashKey] case final st? when st != 404)
          SelKey(r.lib, r.key),
      // trashKey を返さん古い Worker の分は戻す手段が無い
      for (final u in res.unrestorable) SelKey(u.lib, u.key),
    };
    if (gone.isNotEmpty) removeRows((it) => gone.contains(selKeyOf(it, lib)));
    _saveSnapshot(lib);
    if (res.unrestorable.isEmpty) return out;
    return RestoreOutcome(
      total: out.total + res.unrestorable.length,
      restored: out.restored,
      conflict: out.conflict,
      readOnly: out.readOnly,
      notFound: out.notFound,
      other: out.other + res.unrestorable.length,
      failures: out.failures,
    );
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
      if (lib != null && !_disposed) {
        unawaited(_adoptStoredThumbs(lib, storedVideos));
      }
    }();
  }

  String _idOf(MediaItem it, String fallbackLib) =>
      '${it.lib ?? fallbackLib}:${it.key}';

  /// サムネを保存できた動画の行だけを、サーバーの最新の行に差し替える。
  /// refresh() は先頭 1 ページに巻き戻して続きページを捨て、スクロール位置が飛ぶので使わない。
  /// 一覧は今の並び順で積まれているため、対象が見つかるまで先頭から読み込み済みの件数分だけ辿る。
  Future<void> _adoptStoredThumbs(String lib, Set<String> ids) async {
    final e = epoch;
    final pending = {...ids};
    final loaded = items.length;
    var walked = 0;
    String? cur;
    try {
      while (pending.isNotEmpty && !_disposed) {
        // items は今の並び順で積まれているので、同じ範囲・同じ並びで辿らないと見つからない
        final page = await api.folder(lib,
            prefix: prefix,
            cursor: cur,
            recursive: recursive,
            sort: sort.apiValue,
            type: kind.apiValue);
        if (e != epoch) return;
        final fresh = {
          for (final it in page.items.where(kind.matches)) _idOf(it, lib): it
        };
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

/// 一覧から先に外した1行。[prevId] は外す直前に1つ前にあった行で、戻す時の目印にする。
class RemovedRow {
  final MediaItem item;
  final int index;
  final String? prevId;
  const RemovedRow(this.item, this.index, this.prevId);
}

/// 先に一覧から外し、裏でゴミ箱へ送っている途中の操作。
class PendingTrash {
  /// 送った件数（読み込み前の行も含む）。「N件をゴミ箱に移しました」に使う
  final int count;
  final List<RemovedRow> rows;

  /// ゴミ箱へ送り終わった結果。戻すための trashKey はここで揃う
  final Future<TrashOutcome> done;
  const PendingTrash(this.count, this.rows, this.done);
}
