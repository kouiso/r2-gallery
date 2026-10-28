import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../state/app_state.dart';
import '../transfer/transfer_rows.dart';
import '../ui/app_lock_layer.dart';
import '../ui/theme.dart';
import 'offline_store.dart';

/// 設定の「オフライン保存」グループ（KMP 版 SettingsContent と同じ：件数・一覧・すべて削除）。
class OfflineSettingsCard extends StatefulWidget {
  final AppState app;
  const OfflineSettingsCard({super.key, required this.app});

  @override
  State<OfflineSettingsCard> createState() => _OfflineSettingsCardState();
}

class _OfflineSettingsCardState extends State<OfflineSettingsCard> {
  int? _count;

  @override
  void initState() {
    super.initState();
    widget.app.offline.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.app.offline.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final n = await widget.app.offline.count();
    if (mounted) setState(() => _count = n);
  }

  Future<void> _deleteAll() async {
    final n = _count ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('オフライン保存をすべて削除しますか？'),
        content: Text('端末に保存した $n 件を削除します。サーバー上の写真・動画は消えません。'),
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
    if (ok != true) return;
    await widget.app.offline.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('オフライン保存を削除しました')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.app.offlineSupported) return const SizedBox.shrink();
    final n = _count;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.download_done, color: AppColors.accent),
              title: const Text('オフライン保存'),
              subtitle: Text(n == null ? '…' : '$n件',
                  style:
                      const TextStyle(color: AppColors.textDim, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => OfflineListScreen(app: widget.app))),
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

  @override
  void initState() {
    super.initState();
    widget.app.offline.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.app.offline.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final list = await widget.app.offline.list();
    if (mounted) setState(() => _items = list);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('オフライン保存')),
      body: items == null
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
                        tooltip: '端末から削除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            widget.app.offline.remove(r.lib, r.key),
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
  const OfflineViewer({super.key, required this.app, required this.item});

  @override
  State<OfflineViewer> createState() => _OfflineViewerState();
}

class _OfflineViewerState extends State<OfflineViewer> with PauseOnLock {
  Uint8List? _bytes;
  VideoPlayerController? _video;
  File? _temp;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final r = widget.item;
    final bytes = await widget.app.offlineBytes(r.lib, r.key);
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _error = '端末の保存データを読めませんでした');
      return;
    }
    if (!r.entry.isVideo) {
      setState(() => _bytes = bytes);
      return;
    }
    try {
      // 再生器はファイルからしか読めない。アプリ専用の一時領域に置き、閉じる時に消す
      final dir = await Directory.systemTemp.createTemp('r2g-offline-');
      final f = File('${dir.path}/play.mp4');
      await f.writeAsBytes(bytes, flush: true);
      _temp = f;
      final c = VideoPlayerController.file(f);
      _video = c;
      await c.initialize();
      if (!mounted) return;
      setState(() {});
      if (!isAppLocked) unawaited(c.play());
    } on Exception catch (e) {
      if (mounted) setState(() => _error = '再生できませんでした（$e）');
    }
  }

  @override
  void onLocked() {
    _video?.pause();
  }

  @override
  void dispose() {
    _video?.dispose();
    final dir = _temp?.parent;
    if (dir != null) {
      unawaited(dir.delete(recursive: true).then((_) {}, onError: (Object e) {
        // 消し損ねても OS の一時領域の掃除で消える
        debugPrint('offline temp not removed: $e');
      }));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final bytes = _bytes;
    Widget body;
    if (_error != null) {
      body = Text(_error!, style: const TextStyle(color: AppColors.textDim));
    } else if (bytes != null) {
      body = InteractiveViewer(child: Image.memory(bytes));
    } else if (video != null && video.value.isInitialized) {
      body = GestureDetector(
        onTap: () => setState(
            () => video.value.isPlaying ? video.pause() : video.play()),
        child: AspectRatio(
            aspectRatio: video.value.aspectRatio, child: VideoPlayer(video)),
      );
    } else {
      body = const CircularProgressIndicator();
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(widget.item.entry.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(child: body),
    );
  }
}
