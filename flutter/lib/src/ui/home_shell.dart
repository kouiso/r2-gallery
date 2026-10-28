import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../albums/album_detail_screen.dart';
import '../api/models.dart';
import '../grid/selection_widgets.dart';
import '../state/app_state.dart';
import '../transfer/transfers_strip.dart';
import 'albums_tab.dart';
import 'connect_screen.dart';
import 'folder_browse_screen.dart';
import 'gallery_tab.dart';
import 'import_browser_tab.dart';
import 'library_parts.dart';
import 'lock_gate.dart';
import 'settings_tab.dart';
import 'theme.dart';
import 'trash_tab.dart';

/// メインシェル。ライブラリタブ + 4タブ（写真/アルバム/取り込み/設定）。
/// タブの数・順番・行き先は Kotlin 版（BottomTabs.kt）と同じ。アルバム詳細・フォルダ・ゴミ箱は
/// アルバムタブの子画面で、開いている間も下タブを出したままアルバムタブを点ける（Kotlin 版 selectedTabRoute、#167）。
class HomeShell extends StatefulWidget {
  final AppState app;
  /// 最初に開く画面。省くと Kotlin 版と同じく取り込みから始める（startDestination = "browser"）
  final int? initialTab;
  const HomeShell({super.key, required this.app, this.initialTab});

  static const photosTab = 0;
  static const albumsTab = 1;
  static const importTab = 2;
  static const settingsTab = 3;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// アルバムタブの上に積む子画面。閉じた時に [closed] が終わるので、開いた側は戻ってから読み直せる
sealed class _AlbumsChild {
  final Completer<void> closed = Completer<void>();
}

class _AlbumChild extends _AlbumsChild {
  final String lib;
  final Album album;
  _AlbumChild(this.lib, this.album);
}

class _FolderChild extends _AlbumsChild {
  final String lib;
  final String prefix;
  _FolderChild(this.lib, this.prefix);
}

class _TrashChild extends _AlbumsChild {}

class _HomeShellState extends State<HomeShell> {
  // 表示中のタブ。下タブと同じ並び。
  // 起動は Kotlin 版と同じく取り込みから（#167）。接続せずに使う時も取り込みはそのまま使える
  late int _tab = widget.initialTab ?? _importTab;
  // アルバムタブの子画面の積み上げ。タブを移っても残し、戻ってきた時に続きを出す
  // （Kotlin 版はタブ移動で saveState / restoreState するので、開いていた子画面に戻る）
  final List<_AlbumsChild> _albumsStack = [];
  // 子画面（アルバム詳細・フォルダ）で選択中か。選択中は下タブと転送バーを隠し、子画面の操作バーだけにする
  bool _childSelecting = false;
  // 開いたことのある画面だけ作る。未表示のアルバム/ゴミ箱までライブラリ切替のたびに取り直すと、
  // 写真の一覧と回線を奪い合って切替が遅くなる
  late final Set<int> _opened = {0, _tab};
  // 子画面を積んだ時のライブラリ。写真タブでライブラリを替えたら、前のライブラリの子画面は捨てる
  String? _stackLib;
  // 取り込みタブで内蔵ブラウザを開いている間は下タブを隠す（#165）
  bool _browserOpen = false;

  static const _albumsTab = HomeShell.albumsTab;
  static const _importTab = HomeShell.importTab;
  static const _settingsTab = HomeShell.settingsTab;

  @override
  void initState() {
    super.initState();
    _stackLib = widget.app.activeLib;
    widget.app.addListener(_onAppChanged);
  }

  @override
  void didUpdateWidget(HomeShell old) {
    super.didUpdateWidget(old);
    if (old.app != widget.app) {
      old.app.removeListener(_onAppChanged);
      widget.app.addListener(_onAppChanged);
      _onAppChanged();
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    super.dispose();
  }

  // 開いたままのアルバム・フォルダは開いた時のライブラリの中身を持つ。別のライブラリに替えたら残すと
  // 前のライブラリの写真を見せたまま操作させてしまうので捨てる。ゴミ箱は今のライブラリを追うので残す
  void _onAppChanged() {
    final lib = widget.app.activeLib;
    if (lib == _stackLib) return;
    _stackLib = lib;
    final stale = [
      for (final c in _albumsStack)
        if (c is! _TrashChild) c
    ];
    if (stale.isEmpty || !mounted) return;
    void drop() {
      if (!mounted) return;
      setState(() {
        for (final c in stale) {
          _albumsStack.remove(c);
          c.closed.complete();
        }
        _childSelecting = false;
      });
    }

    // 画面の組み立て中に通知が来た時は、描画後に反映する
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => drop());
    } else {
      drop();
    }
  }

  void _goTab(int i) => setState(() {
        _tab = i;
        _opened.add(i);
      });

  Future<void> _pushAlbums(_AlbumsChild c) {
    setState(() => _albumsStack.add(c));
    return c.closed.future;
  }

  void _popAlbums() {
    if (_albumsStack.isEmpty) return;
    setState(() {
      _albumsStack.removeLast().closed.complete();
      _childSelecting = false;
    });
  }

  void _onChildSelecting(bool selecting) {
    void apply() {
      if (mounted && _childSelecting != selecting) {
        setState(() => _childSelecting = selecting);
      }
    }

    // 子画面の一覧の作り直し中（build の最中）に選択が変わった時は、描画後に反映する
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _onBrowserOpenChanged(bool open) {
    if (_browserOpen != open) setState(() => _browserOpen = open);
  }

  // 写真・アルバム・ゴミ箱はライブラリが要る。未接続なら接続画面（スキップで取り込みへ）、
  // ライブラリが来ていなければその理由を出す。取り込みと設定はライブラリ無しでも開ける
  Widget _needsLibrary(Widget Function(String lib) build) {
    final app = widget.app;
    if (!app.connected) {
      return ConnectScreen(app: app, onSkip: () => _goTab(_importTab));
    }
    final lib = app.activeLib;
    if (lib == null) return NoLibraryView(app: app);
    return build(lib);
  }

  // 写真タブで選択中は、上をその選択の見出しに、下のタブを操作バーに置き換える
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.app.photosChrome,
      builder: (context, _) => _shell(context));

  // アルバムタブの中身。一覧の上に子画面を積み、一番上だけを見せる。下の画面は状態ごと残す
  Widget _albumsSlot(String lib) {
    final app = widget.app;
    final visible = _tab == _albumsTab;
    return IndexedStack(
      index: _albumsStack.length,
      sizing: StackFit.expand,
      children: [
        AlbumsTab(
          app: app,
          lib: lib,
          active: visible && _albumsStack.isEmpty,
          onOpenTrash: () => _pushAlbums(_TrashChild()),
          onOpenAlbum: (a) => _pushAlbums(_AlbumChild(lib, a)),
          onOpenFolder: (p) => _pushAlbums(_FolderChild(lib, p)),
        ),
        for (final (i, c) in _albumsStack.indexed)
          KeyedSubtree(
            key: ObjectKey(c),
            child: switch (c) {
              _AlbumChild() => AlbumDetailScreen(
                  app: app,
                  lib: c.lib,
                  album: c.album,
                  onBack: _popAlbums,
                  active: visible && i == _albumsStack.length - 1,
                  onSelectingChanged: _onChildSelecting),
              _FolderChild() => FolderBrowseScreen(
                  app: app,
                  lib: c.lib,
                  prefix: c.prefix,
                  onBack: _popAlbums,
                  onOpenFolder: (p) => _pushAlbums(_FolderChild(c.lib, p)),
                  active: visible && i == _albumsStack.length - 1,
                  onSelectingChanged: _onChildSelecting),
              _TrashChild() => TrashTab(
                  app: app,
                  lib: lib,
                  active: visible && i == _albumsStack.length - 1),
            },
          ),
      ],
    );
  }

  Widget _shell(BuildContext context) {
    final app = widget.app;
    final lib = app.activeLib;
    final libs = app.libraries;
    final chrome = app.photosChrome;
    final selSurface = _tab == 0 && chrome.selecting ? chrome.surface : null;
    final albumsTop = _tab == _albumsTab && _albumsStack.isNotEmpty
        ? _albumsStack.last
        : null;
    final inTrash = albumsTop is _TrashChild;
    // アルバム詳細・フォルダは自分の見出し（戻る付き）を持つので、シェルの見出しは出さない
    final childOwnsAppBar = albumsTop != null &&
        albumsTop is! _TrashChild &&
        app.connected &&
        lib != null;
    final childSelecting = albumsTop != null && _childSelecting;
    final hideTabs = _tab == _importTab && _browserOpen;
    return PopScope(
      // 戻るの行き先は Kotlin 版と同じ。アルバムの子画面→一つ前、ほかのタブ→取り込み、取り込みでだけアプリを閉じる。
      // Kotlin 版はタブ移動のたびに起動画面（取り込み）まで積み直すので、戻ると必ず取り込みに着く（#167）
      canPop: _tab == _importTab,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // 子画面の選択中は、子画面側が選択を解くだけにする
        if (childSelecting) return;
        if (albumsTop != null) {
          _popAlbums();
        } else if (_tab != _importTab && selSurface == null) {
          // 写真の選択中は、写真タブ側が選択を解くだけにする（その戻るでタブまでは動かさない）
          _goTab(_importTab);
        }
      },
      child: Scaffold(
      appBar: selSurface != null ? selectionAppBar(selSurface) : childOwnsAppBar ? null : AppBar(
        leading: inTrash
            ? BackButton(onPressed: _popAlbums)
            : null,
        title: Text(inTrash ? 'ゴミ箱' : 'R2 Gallery'),
        actions: [
          if (_tab == 0)
            SortMenuButton(
                current: chrome.sort, onPick: (m) => chrome.sort = m),
          IconButton(
            tooltip: '今すぐロック',
            icon: const Icon(Icons.lock_outline, size: 20),
            onPressed: () => lockNowOrExplain(context, app),
          ),
        ],
        bottom: libs.length > 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(44),
                // ライブラリが多くても全部選べるよう横に送れるようにする
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      for (final l in libs)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: LibraryLabel(library: l),
                            selected: l.id == lib,
                            onSelected: (_) => app.setLib(l.id),
                            selectedColor: AppColors.accentSoft,
                            labelStyle: TextStyle(
                              color: l.id == lib
                                  ? AppColors.accent
                                  : AppColors.textDim,
                              fontWeight: l.id == lib
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                            side: BorderSide(
                              color:
                                  l.id == lib ? AppColors.accent : AppColors.border,
                            ),
                            backgroundColor: AppColors.surface,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20)),
                          ),
                        ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: IndexedStack(
              index: _tab,
              children: [
                _needsLibrary((lib) => GalleryTab(
                      app: app,
                      lib: lib,
                      onOpenSettings: () => _goTab(_settingsTab),
                    )),
                _opened.contains(_albumsTab)
                    ? _needsLibrary(_albumsSlot)
                    : const SizedBox.shrink(),
                // 内蔵ブラウザ（WebView）は重いので、開いた時だけ作る
                _opened.contains(_importTab)
                    ? ImportBrowserTab(
                        app: app, onBrowserOpenChanged: _onBrowserOpenChanged)
                    : const SizedBox.shrink(),
                _opened.contains(_settingsTab)
                    ? SettingsTab(app: app)
                    : const SizedBox.shrink(),
              ],
            ),
      // 転送バーは下タブの上に常駐させ、どのタブからでも転送の状況を開けるようにする（#149）。
      // 写真タブで選択中は、下タブの代わりに選択の操作バーを出す（#146）。
      // ブラウザ表示中は下タブだけ外し、取り込みの進み具合が見える転送バーは残す（#165）
      bottomNavigationBar: selSurface != null
          ? SelectionOpsBar(actions: selSurface.selectionActions(context))
          : childSelecting
              // 子画面は自分の操作バーを下端に出す（Kotlin 版も選択中は下タブと転送バーを操作バーに置き換える）
              ? null
          : hideTabs
              // 下タブが持っていた下端の余白（ジェスチャー帯）を残し、転送バーと取り込み画面を帯に潜らせない
              ? SafeArea(
                  top: false,
                  child: TransfersDock(app: app, child: const SizedBox.shrink()))
              : TransfersDock(app: app, child: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _goTab,
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.accentSoft,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.photo_outlined),
              selectedIcon: Icon(Icons.photo),
              label: '写真'),
          NavigationDestination(
              icon: Icon(Icons.photo_album_outlined),
              selectedIcon: Icon(Icons.photo_album),
              label: 'アルバム'),
          NavigationDestination(
              icon: Icon(Icons.public_outlined),
              selectedIcon: Icon(Icons.public),
              label: '取り込み'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '設定'),
        ],
      )),
      ),
    );
  }
}
