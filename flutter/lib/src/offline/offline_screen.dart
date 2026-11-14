import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../state/app_state.dart';
import '../transfer/transfer_rows.dart';
import '../ui/app_lock_layer.dart';
import '../ui/theme.dart';
import '../viewer/screen_awake.dart';
import '../playback/mobile_playback.dart';
import '../playback/playback_session.dart';
import '../playback/playback_menu.dart';
import 'offline_store.dart';
import 'offline_playback_files.dart';

/// 設定の「オフライン保存」グループ（KMP 版 SettingsContent と同じ：件数・一覧・すべて削除）。
class OfflineSettingsCard extends StatefulWidget {
  final AppState app;
  const OfflineSettingsCard({super.key, required this.app});

  @override
  State<OfflineSettingsCard> createState() => _OfflineSettingsCardState();
}

class _OfflineSettingsCardState extends State<OfflineSettingsCard> {
  int? _count;
  int? _bytes;
  bool _legacy = false;
  bool _loadError = false;
  OfflineStore? _store;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onAppChanged);
    _onAppChanged();
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    _store?.removeListener(_reload);
    super.dispose();
  }

  void _onAppChanged() {
    final next = widget.app.offline;
    final updating = _store != null;
    if (!identical(next, _store)) {
      _store?.removeListener(_reload);
      _store = next;
      next.addListener(_reload);
    }
    _count = null;
    _bytes = null;
    _legacy = false;
    _loadError = false;
    if (updating && mounted) setState(() {});
    _reload();
  }

  Future<void> _reload() async {
    final request = ++_request;
    final store = _store!;
    if (!widget.app.offlineSupported || !widget.app.offlineAccessible) {
      if (mounted) setState(() {});
      return;
    }
    try {
      final list = (await store.list())
          .where((r) => widget.app.canReadOffline(r.lib)).toList();
      final legacy = await store.hasLegacyData();
      if (!mounted || request != _request ||
          !identical(store, widget.app.offline) || !widget.app.offlineAccessible) {
        return;
      }
      setState(() {
        _loadError = false;
        _count = list.length;
        _bytes = list.fold<int>(0, (total, ref) => total + ref.entry.size);
        _legacy = legacy;
      });
    } catch (_) {
      if (mounted && request == _request) setState(() => _loadError = true);
    }
  }

  Future<void> _deleteAll() async {
    final store = _store!;
    if (!widget.app.offlineAccessible) return;
    final n = _count ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('オフライン保存をすべて削除しますか？'),
        content: Text('この接続のアプリ内保存 $n 件を削除します。サーバー上や外部ギャラリーのファイルは消えません。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除')),
        ],
      ),
    );
    if (ok != true || !widget.app.offlineAccessible ||
        !identical(store, widget.app.offline)) {
      return;
    }
    final refs = await store.list();
    for (final ref in refs) {
      if (!widget.app.offlineAccessible || !identical(store, widget.app.offline)) return;
      if (widget.app.canReadOffline(ref.lib)) await store.remove(ref.lib, ref.key);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('オフライン保存を削除しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.app.offlineSupported) {
      return const Card(child: ListTile(
        leading: Icon(Icons.download_for_offline_outlined),
        title: Text('アプリ専用保存'),
        subtitle: Text('この環境では利用できません。Web版はアプリ専用保存に対応していません。'),
      ));
    }
    final n = _count;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.download_done, color: AppColors.accent),
              title: const Text('オフライン保存'),
              subtitle: Text(!widget.app.offlineAccessible
                  ? '接続とロック解除が必要です'
                  : _loadError ? '保存の一覧を読めませんでした'
                  : n == null ? '…' : '$n件 · ${formatBytes(_bytes ?? 0)} · このアプリ内のみ',
                  style:
                      const TextStyle(color: AppColors.textDim, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: !widget.app.offlineAccessible ? null : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => OfflineListScreen(app: widget.app))),
            ),
            if (_legacy)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text('以前の保存は接続先を確認できないため隔離しています。自動移行・削除はしていません。'),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text('保存は接続ごとに分かれます。ログアウトや接続切替では消しません。アプリの削除やOSのデータ消去で失われます。'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined,
                  color: AppColors.danger),
              title: const Text('オフライン保存をすべて削除'),
              enabled: (n ?? 0) > 0,
              onTap: _deleteAll,
            ),
          ],
        ),
      ),
    );
  }
}

/// 端末に保存した写真・動画の一覧。回線が無くても開ける。
class OfflineListScreen extends StatefulWidget {
  final AppState app;
  const OfflineListScreen({super.key, required this.app});

  @override
  State<OfflineListScreen> createState() => _OfflineListScreenState();
}

class _OfflineListScreenState extends State<OfflineListScreen> {
  List<OfflineRef>? _items;
  bool _loadError = false;
  OfflineStore? _store;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onAppChanged);
    _onAppChanged();
    unawaited(OfflinePlaybackFiles.shared.cleanOrphans().catchError((Object _) {
      debugPrint('offline playback cache sweep unavailable');
    }));
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    _store?.removeListener(_reload);
    super.dispose();
  }

  void _onAppChanged() {
    final next = widget.app.offline;
    final updating = _store != null;
    if (!identical(next, _store)) {
      _store?.removeListener(_reload);
      _store = next;
      next.addListener(_reload);
    }
    _items = null;
    _loadError = false;
    if (updating && mounted) setState(() {});
    _reload();
  }

  Future<void> _reload() async {
    final request = ++_request;
    final store = _store!;
    if (!widget.app.offlineAccessible) {
      if (mounted) setState(() => _items = const []);
      return;
    }
    try {
      final list = (await store.list())
          .where((r) => widget.app.canReadOffline(r.lib)).toList();
      if (mounted && request == _request &&
          identical(store, widget.app.offline) && widget.app.offlineAccessible) {
        setState(() {
          _loadError = false;
          _items = list;
        });
      }
    } catch (_) {
      if (mounted && request == _request) setState(() => _loadError = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('オフライン保存')),
      body: !widget.app.offlineAccessible
          ? const Center(child: Text('保存を開くには接続とロック解除が必要です'))
          : _loadError
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('保存の一覧を読めませんでした'),
              TextButton(onPressed: _reload, child: const Text('再読み込み')),
            ]))
          : items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Text('オフライン保存はまだありません',
                      style: TextStyle(color: AppColors.textDim)))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final r = items[i];
                    return ListTile(
                      leading: Icon(
                          r.entry.isVideo
                              ? Icons.play_circle_outline
                              : Icons.image_outlined,
                          color: AppColors.accent),
                      title: Text(r.entry.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(formatBytes(r.entry.size),
                          style: const TextStyle(
                              color: AppColors.textDim, fontSize: 12)),
                      trailing: IconButton(
                        tooltip: 'アプリ内の保存を削除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          if (widget.app.canReadOffline(r.lib) &&
                              r.accountId == widget.app.offline.accountId) {
                            widget.app.offline.remove(r.lib, r.key);
                          }
                        },
                      ),
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              fullscreenDialog: true,
                              builder: (_) =>
                                  OfflineViewer(app: widget.app, item: r))),
                    );
                  },
                ),
    );
  }
}

/// オフライン保存した1件を、端末の中身だけで見る。動画は再生のあいだだけ一時ファイルに復号し、閉じたら消す。
class OfflineViewer extends StatefulWidget {
  final AppState app;
  final OfflineRef item;
  final OfflinePlaybackFiles? playbackFiles;
  final VideoPlayerController Function(File)? controllerFactory;
  final ScreenAwakeCoordinator? screenAwake;
  final PlaybackCoordinator? playbackCoordinator;
  const OfflineViewer({super.key, required this.app, required this.item,
    @visibleForTesting this.playbackFiles,
    @visibleForTesting this.controllerFactory,
    @visibleForTesting this.screenAwake,
    @visibleForTesting this.playbackCoordinator});

  @override
  State<OfflineViewer> createState() => _OfflineViewerState();
}

class _OfflineViewerState extends State<OfflineViewer>
    with PauseOnLock, WidgetsBindingObserver {
  late final OfflineStore _store;
  Uint8List? _bytes;
  VideoPlayerController? _video;
  PlaybackBinding? _playback;
  final _surfaceKey = GlobalKey();
  PlaybackSession? get _session => _playback?.session;
  bool get _pipMode => (_session?.pip ?? false) || (_session?.pipPending ?? false);
  OfflinePlaybackFile? _temp;
  String? _error;
  int _request = 0;
  int _playEpoch = 0;
  bool _background = false;
  bool _resumePlayback = false;
  bool _pendingPlay = false;

  bool get _foreground {
    final state = WidgetsBinding.instance.lifecycleState;
    return !_background && (state == null || state == AppLifecycleState.resumed);
  }

  bool get _authorized => widget.item.accountId != null &&
      widget.item.accountId == widget.app.offline.accountId &&
      widget.app.canReadOffline(widget.item.lib);

  @override
  void initState() {
    super.initState();
    _background = !_foreground;
    WidgetsBinding.instance.addObserver(this);
    widget.app.addListener(_onSessionChanged);
    _store = widget.app.offline;
    _store.addListener(_onSavedChanged);
    _open();
  }

  void _onSavedChanged() {
    if (_store.hasCached(widget.item.lib, widget.item.key)) return;
    _request++;
    _dropImage();
    _error = 'アプリ内の保存が削除されました';
    unawaited(_releasePlayback());
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    if (_authorized) return;
    _request++;
    _dropImage();
    _error = '保存を開くには同じ接続とロック解除が必要です';
    unawaited(_releasePlayback());
    if (mounted) setState(() {});
  }

  void _dropImage() {
    final bytes = _bytes;
    _bytes = null;
    if (bytes != null) unawaited(MemoryImage(bytes).evict());
  }

  Future<void> _releasePlayback() async {
    _playEpoch++;
    _resumePlayback = false;
    _pendingPlay = false;
    final video = _video;
    final playback = _playback;
    final temp = _temp;
    _video = null;
    _playback = null;
    _temp = null;
    try {
      if (playback != null) {
        playback.session.removeListener(_onPlaybackChanged);
        await playback.close();
      } else {
        await video?.dispose();
      }
    } catch (_) {
      debugPrint('offline player disposal failed');
    } finally {
      await temp?.dispose();
    }
  }

  Future<void> _open() async {
    final request = ++_request;
    if (!_authorized) {
      _error = '保存を開くには同じ接続とロック解除が必要です';
      return;
    }
    final r = widget.item;
    Uint8List? bytes;
    try {
      bytes = await widget.app.offlineBytes(r.lib, r.key);
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => _error = '端末の保存データを読めませんでした');
      }
      return;
    }
    if (!mounted || request != _request || !_authorized) return;
    if (bytes == null) {
      setState(() => _error = '端末の保存データを読めませんでした');
      return;
    }
    if (!r.entry.isVideo) {
      setState(() => _bytes = bytes);
      return;
    }
    try {
      final temp = await (widget.playbackFiles ?? OfflinePlaybackFiles.shared).create(bytes);
      if (!mounted || request != _request || !_authorized) {
        await temp.dispose();
        return;
      }
      _temp = temp;
      final c = widget.controllerFactory?.call(temp.file) ??
          VideoPlayerController.file(temp.file, videoPlayerOptions: MobilePlayback.options());
      _video = c;
      _playback = PlaybackBinding.attach(controller: c, app: widget.app,
        library: r.lib, coordinator: widget.playbackCoordinator,
        canAccess: () => _authorized && _store.hasCached(r.lib, r.key));
      _session?.addListener(_onPlaybackChanged);
      await (_session?.initialize() ?? c.initialize());
      if (!mounted || request != _request || !_authorized || _video != c) return;
      setState(() {});
      await _playWhenAuthorized(c, request, _playEpoch);
    } catch (_) {
      await _releasePlayback();
      if (mounted && request == _request) {
        setState(() => _error = '再生できませんでした');
      }
    }
  }

  Future<void> _playWhenAuthorized(
      VideoPlayerController video, int request, int epoch) async {
    if (!_foreground || !_authorized || isAppLocked) return;
    _pendingPlay = true;
    try {
      // 復帰時の非同期ロック判定を待ち、待機中の退出や手動停止も再確認する。
      await widget.app.foregroundSettled;
      if (!mounted || request != _request || epoch != _playEpoch ||
          _video != video || !_foreground || !_authorized || isAppLocked) {
        return;
      }
      if (_session != null) { await _session!.play(); } else { await video.play(); }
    } catch (_) {
      debugPrint('offline playback start failed');
    } finally {
      if (epoch == _playEpoch && _video == video) _pendingPlay = false;
    }
  }

  void _togglePlayback() {
    final video = _video;
    if (video == null || !_authorized || isAppLocked || !_foreground) return;
    final cancel = video.value.isPlaying || _pendingPlay || (_session?.hasPlayIntent ?? false);
    _playEpoch++;
    _resumePlayback = false;
    _pendingPlay = false;
    if (cancel) {
      if (_session != null) { unawaited(_session!.pause()); } else { unawaited(video.pause()); }
    } else {
      unawaited(_playWhenAuthorized(video, _request, _playEpoch));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = _session;
    if (session != null) {
      _background = state != AppLifecycleState.resumed;
      _playEpoch++;
      _resumePlayback = false;
      unawaited(session.lifecycle(state));
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _background = false;
      final video = _video;
      final resume = _resumePlayback;
      _resumePlayback = false;
      if (resume && video != null) {
        unawaited(_playWhenAuthorized(video, _request, _playEpoch));
      }
      return;
    }
    if (!_background) _resumePlayback = _video?.value.isPlaying ?? false;
    _background = true;
    _playEpoch++;
    _pendingPlay = false;
    if (state == AppLifecycleState.detached) _resumePlayback = false;
    unawaited(_video?.pause());
  }

  @override
  void onLocked() {
    _playEpoch++;
    _resumePlayback = false;
    _pendingPlay = false;
    if (_session != null) { unawaited(_session!.stop()); } else { unawaited(_video?.pause()); }
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    if (_session?.closed ?? false) {
      _error = '再生を終了しました';
      unawaited(_releasePlayback());
    }
    setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_onSavedChanged);
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    widget.app.removeListener(_onSessionChanged);
    _dropImage();
    unawaited(_releasePlayback());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final bytes = _bytes;
    Widget body;
    if (!_authorized) {
      body = const Text('保存を開くには同じ接続とロック解除が必要です');
    } else if (_error != null) {
      body = Text(_error!, style: const TextStyle(color: AppColors.textDim));
    } else if (bytes != null) {
      body = InteractiveViewer(child: Image.memory(bytes));
    } else if (video != null && video.value.isInitialized) {
      body = PlaybackScreenAwake(
        key: _surfaceKey,
        controller: video,
        active: _authorized && !isAppLocked,
        coordinator: widget.screenAwake,
        child: GestureDetector(
          key: const ValueKey('offline-video-playback'),
          // 動画の描画面がまだ透明でも、見えている再生領域全体を操作できるようにする。
          behavior: HitTestBehavior.opaque,
          onTap: _pipMode ? null : _togglePlayback,
          child: AspectRatio(
              aspectRatio: video.value.aspectRatio, child: VideoPlayer(video)),
        ),
      );
    } else {
      body = const CircularProgressIndicator();
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _pipMode ? null : AppBar(
        backgroundColor: Colors.black,
        title: Text(_authorized ? widget.item.entry.name : 'アプリ内の保存',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [if (_session != null)
          PlaybackMenu(session: _session!, surfaceKey: _surfaceKey)],
      ),
      body: Center(child: body),
    );
  }
}
